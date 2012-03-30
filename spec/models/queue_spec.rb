require "spec_helper"

describe Sym::Queue do
  it "should identify the list of queues" do
    Sym::Queue::INDEX.should == "queues"
  end

  it "should default to 'default'" do
    Sym::Queue::DEFAULT.should == "default"
  end

  describe ".new" do
    it "should be the default queue" do
      Sym::Queue.new.name.should == "queues:default"
    end

    it "should add itself to the list of queues" do
      Sym::Queue.new("queue_name")

      Sym.redis.with {|redis| redis.smembers(Sym::Queue::INDEX).include?("queue_name").should be_true }
    end
  end

  describe "#id" do
    it "should default to `default`" do
      Sym::Queue.new.id.should == "default"
    end

    it "should be the given queue identifier" do
      Sym::Queue.new("queue_name").id.should == "queue_name"
    end
  end

  describe "#name" do
    it "should be the namespaced queue name that is passed in" do
      Sym::Queue.new("queue_name").name.should == "queues:queue_name"
    end
  end

  describe "#created_at" do
    it "should return the created time" do
      Timecop.freeze(DateTime.now) do
        subject.created_at.should == Time.now
      end
    end
  end

  describe "#push" do
    let!(:message) { mock(Sym::Message) }
    let!(:encoded_message) { mock("JSON:Sym::Message") }

    before do
      MultiJson.stub(:encode).and_return(encoded_message)
    end

    it "should JSON encode the message" do
      MultiJson.should_receive(:encode).with(message)

      subject.push(message)
    end

    it "should push the message into redis" do
      Timecop.freeze(DateTime.now) do
        Sym.send(:_redis).should_receive(:zadd).with(Sym::Manager::DEFAULT, Time.now.to_f, encoded_message)

        subject.push(message)
      end
    end

    it "should return true" do
      Sym.send(:_redis).stub(:zadd).and_return(1)

      subject.push(message).should == true
    end

    describe "when the message cannot be pushed" do
      it "should return false" do
        Sym.send(:_redis).stub(:zadd).and_return(0)

        subject.push(message).should == false
      end
    end
  end

  describe "#immediate" do
    let!(:worker) { mock(Sym::Worker) }
    let(:message) { mock(Sym::Message, :klass => 1, :method => 2, :args => 3, :created_at => 4) }

    it "should perform the method now" do
      Sym::Worker.should_receive(:new).and_return(worker)
      worker.should_receive(:perform).with(message, subject)

      subject.immediate(message)
    end
  end

  describe "#success" do
    before do
      2.times { subject.statistics { lambda {} } }
    end

    describe "when the given block is successful" do
      it "should return the number of messages processed" do
        subject.success.should == 2
      end
    end
  end

  describe "#error" do
    describe "when the given block raises an exception" do
      before do
        3.times { subject.statistics { raise "failed" } }
      end

      it "should return the number of errors encountered" do
        subject.error.should == 3
      end
    end
  end

  describe "#statistics" do
    let(:block) { lambda {} }
    let!(:benchmark) { "0.1 0.3 0.5 ( 1.1)" }

    it "should call the given block" do
      block.should_receive(:call)

      subject.statistics(&block)
    end

    it "should store metadata about each message" do
      now = Time.now
      Time.stub(:now).and_return(now)

      Benchmark.stub(:measure).and_return(benchmark)

      metadata = MultiJson.encode(
        :class => "Array",
        :method => "length",
        :args => 1234,
        :time => { :system => 0.5, :user => 1.1 },
        :created_at => nil,
        :status => 'success'
      )

      Sym.send(:_redis).should_receive(:zadd).with("#{subject.name}:messages", now.to_f, metadata)

      subject.statistics(Array, :length, 1234, &block)
    end

    describe "when given the class" do
      it "should increment the class' total in redis" do
        Sym.send(:_redis).should_receive(:hincrby).with(subject.name, "Array", 1)

        subject.statistics(Array, &block)
      end
    end

    describe "when given the method name" do
      before do
        Sym.send(:_redis).stub(:hincrby)
      end

      it "should store the method in redis" do
        Sym.send(:_redis).should_receive(:hincrby).with(subject.name, "Array:length", 1)

        subject.statistics(Array, :length, &block)
      end
    end

    describe "when given arguments" do
      before do
        Sym.send(:_redis).stub(:hincrby)
      end

      it "should store the method in redis" do
        Sym.send(:_redis).should_receive(:hincrby).with(subject.name, "Array:length", 1)

        subject.statistics(Array, :length, 1234, &block)
      end
    end

    describe "when the given block is successful" do
      it "should update the success count" do
        expect {
          subject.statistics(&block)
        }.to change(subject, :success).by(1)
      end

      it "should not update the error count" do
        expect {
          subject.statistics(&block)
        }.not_to change(subject, :error)
      end
    end

    describe "when the given block encounters an error" do
      before do
        block.stub(:call).and_raise(Exception)
      end

      it "should not update the success count" do
        expect {
          subject.statistics(&block)
        }.not_to change(subject, :success)
      end

      it "should update the error count" do
        expect {
          subject.statistics(&block)
        }.to change(subject, :error).by(1)
      end
    end

    describe "storing the queue's messages" do
      let!(:benchmark) { "0.1 0.2 0.3 ( 1.1)" }

      describe "when there are messages to be processed" do
        before do
          Sym::Manager.push(Array, :length, nil)
          Sym::Manager.push(Hash, :keys, nil)
        end

        it "should return a list of pending messages" do
          subject.pending_messages.collect {|p| p['class']}.should == %w(Array Hash)
          subject.pending_messages.collect {|p| p['method']}.should == %w(length keys)
        end

        it "should update when more messages are pushed" do
          Sym::Manager.push(Thread, :current, nil)

          subject.pending_messages.collect {|p| p['class']}.should == %w(Array Hash Thread)
          subject.pending_messages.collect {|p| p['method']}.should == %w(length keys current)
        end
      end

      describe "when messages have been processed" do
        before do
          Benchmark.stub(:measure).and_return(benchmark)
        end

        it "should store metadata" do
          Sym.send(:_redis).should_receive(:zadd).with(subject.name + ":messages", anything, anything)

          subject.statistics(&block)
        end

        it "should benchmark the runtime" do
          Benchmark.should_receive(:measure)

          subject.statistics(&block)
        end

        it "should have the message" do
          subject.statistics(&block)

          subject.should have(1).processed_messages
        end

        it "should be a message" do
          subject.statistics(Array, :length, 1234, '10-10', &block)

          subject.processed_messages.first.should == {
            'class' => 'Array',
            'method' => 'length',
            'args' => 1234,
            'time' => {'system' => 0.3, 'user' => 1.1},
            'status' => 'success',
            'created_at' => '10-10'
          }
        end

        it "should include system time" do
          subject.statistics(&block)

          subject.processed_messages.first['time']['system'].should == 0.3
        end

        it "should include user time" do
          subject.statistics(&block)

          subject.processed_messages.first['time']['user'].should == 1.1
        end

        describe "when a message fails" do
          before do
            Benchmark.unstub(:measure)

            subject.statistics { raise Sym::Message::Failed }
          end

          it "should add the messages to the :failed list" do
            subject.should have(1).failed_messages
          end

          it "should not add it to the processed messages list" do
            subject.should have(0).processed_messages
          end

          it "should log error" do
            subject.failed_messages.first['status'].should == 'failed'
          end

          it "should include the failure cause" do
            subject.failed_messages.first['cause'].should == 'Sym::Message::Failed'
          end

          it "should include the failed at time" do
            Timecop.freeze(DateTime.now) do
              subject.statistics { raise Sym::Message::Failed }

              subject.failed_messages.first['failed_at'].should == Time.now.utc.to_f
            end
          end
        end

        describe "status" do
          describe "when the block is successful" do
            it "should log success" do
              subject.statistics(&block)

              subject.processed_messages.first['status'].should == 'success'
            end
          end

          describe "when the block fails" do
            before do
              Benchmark.stub(:measure).and_raise
            end

            it "should log error" do
              subject.statistics(&block)

              subject.processed_messages.first['status'].should == 'error'
            end
          end

          describe "when the message should retry" do
            before do
              Benchmark.unstub(:measure)
            end

            it "should not add the message to the queue.name:messages list" do
              Sym.send(:_redis).should_not_receive(:zadd).with(subject.name + ":messages", anything, anything)

              subject.statistics { raise Sym::Message::Retry }
            end
          end
        end
      end
    end
  end

  describe "#requeue" do
    let(:block) { lambda {} }

    describe "the default behavior" do
      before do
        block.stub(:call).and_raise(Sym::Message::Retry)
      end

      it "should retry the message five minutes later" do
        Timecop.freeze(DateTime.now) do
          Sym.send(:_redis).should_receive(:zadd).with("pending:default", (Time.now + 5.minutes).to_f, anything)

          subject.statistics(&block)
        end
      end
    end

    describe "when the worker encounters an retry-able error" do
      before do
        block.stub(:call).and_raise(Sym::Message::Retry)
        Sym::Message::Retry.any_instance.stub(:at).and_return(60)
      end

      it "should retry the message at the specified time" do
        Timecop.freeze(DateTime.now) do
          Sym.send(:_redis).should_receive(:zadd).with("pending:default", 60.0, anything)

          subject.statistics(&block)
        end
      end

      describe "when the exception specifies a time to live" do
        let!(:message_retry) { Sym::Message::Retry.new(:ttl => -1.minutes) }

        before do
          block.stub(:call).and_raise(message_retry)
        end

        it "should retry the message until it reaches the the ttl" do
          Timecop.freeze(DateTime.now) do
            Sym.send(:_redis).should_not_receive(:zadd).with("pending:default", anything, anything)

            subject.statistics(&block)
          end
        end
      end
    end
  end
end
