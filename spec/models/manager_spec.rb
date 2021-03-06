require "spec_helper"

describe Howler::Manager do
  subject { Howler::Manager.new }

  before do
    subject.wrapped_object.stub(:sleep)
    Howler::Manager.stub(:current).and_return(subject)
  end

  describe ".new" do
    it "should create a Logger" do
      Howler::Logger.should_receive(:new)

      Howler::Manager.new
    end
  end

  describe ".current" do
    before do
      subject.wrapped_object.stub(:sleep)
    end

    it "should return the current manager instance" do
      Howler::Manager.current.wrapped_object.class.should == Howler::Manager
    end
  end

  describe "#run" do
    def build_message(klass, method)
      Howler::Message.new(
        'class' => klass.to_s,
        'method' => method,
        'args' => [],
        'created_at' => Time.now.to_f
      )
    end

    before do
      subject.wrapped_object.stub(:done?).and_return(true)
      Howler::Config[:concurrency] = 10
    end

    it "should create workers" do
      Howler::Worker.should_receive(:new_link).exactly(10)

      subject.run
    end

    describe "when there are no pending messages" do
      before do
        subject.wrapped_object.stub(:done?).and_return(false, true)
      end

      class SampleEx < Exception; end

      describe "when there are no messages" do
        it "should sleep for one second" do
          subject.wrapped_object.should_receive(:sleep).with(1)

          subject.run
        end
      end
    end

    describe "when there are pending messages" do
      before do
        Howler::Config[:concurrency] = 3

        @workers = 3.times.collect do
          mock(Howler::Worker, :perform! => nil)
        end

        subject.wrapped_object.stub(:build_workers).and_return(@workers)
        subject.wrapped_object.stub(:sleep)
        subject.wrapped_object.stub(:done?).and_return(false, true)

        @messages = {
          'length' => build_message(Array, :length),
          'collect' => build_message(Array, :collect),
          'max' => build_message(Array, :max),
          'to_s' => build_message(Array, :to_s)
        }

        %w(length collect max to_s).each do |method|
          Howler::Message.stub(:new).with(hash_including('method' => method)).and_return(@messages[method])
        end
      end

      describe "when there is a single message in the queue" do
        before do
          subject.push(Array, :length, [])
        end

        it "should not sleep" do
          subject.wrapped_object.should_not_receive(:sleep)

          subject.run
        end

        it "should perform the message on a worker" do
          @workers[2].should_receive(:perform!).with(@messages['length'], Howler::Queue::DEFAULT)

          @workers[0].should_not_receive(:perform!)
          @workers[1].should_not_receive(:perform!)

          subject.run
        end

        describe "when a message gets taken by a worker" do
          before do
            @original_workers = @workers.dup
          end

          it "should make the worker unavailable" do
            subject.run

            subject.should have(2).workers
            subject.should have(1).chewing

            subject.workers.should == @original_workers.first(2)
            subject.chewing.should == @original_workers.last(1)
          end
        end
      end

      describe "when there are many messages in the queue" do
        before do
          [:length, :collect, :max].each do |method|
            subject.push(Array, method, [])
          end
        end

        describe "more workers then messages" do
          it "should perform all messages" do
            @workers[2].should_receive(:perform!).with(@messages['length'], anything)
            @workers[1].should_receive(:perform!).with(@messages['collect'], anything)
            @workers[0].should_receive(:perform!).with(@messages['max'], anything)

            subject.run
          end
        end

        describe "more messages then workers" do
          before do
            subject.wrapped_object.stub(:done?).and_return(false, false, true)

            Howler::Config[:concurrency] = 2
          end

          it "should scale and only remove as many messages as workers" do
            @workers[0].unstub(:perform!)

            @workers[1].should_receive(:perform!).with(@messages['length'], anything)
            @workers[0].should_receive(:perform!).with(@messages['collect'], anything)

            subject.run
          end
        end

        describe "run messages in the future" do
          let!(:worker) { mock(Howler::Worker) }

          before do
            subject.wrapped_object.stub(:done?).and_return(false, false, true)
            Howler::Config[:concurrency] = 4

            Howler::Worker.should_receive(:new).once.and_return(worker)

            subject.push(Array, :to_s, [], Time.now + 5.minutes)
          end

          it "should only enqueue messages that are scheduled before now" do
            Timecop.freeze(Time.now) do
              worker.should_receive(:perform!).with(@messages['length'], anything).ordered
              @workers[2].should_receive(:perform!).with(@messages['collect'], anything)
              @workers[1].should_receive(:perform!).with(@messages['max'], anything)

              subject.run

              subject.wrapped_object.stub(:done?).and_return(false, true)

              Timecop.travel(5.minutes) do
                @workers[0].should_receive(:perform!).with(@messages['to_s'], anything).ordered
                subject.run
              end
            end
          end
        end
      end
    end
  end

  describe "logging" do
    let!(:logger) { mock(Howler::Logger) }
    let!(:log) { mock(Howler::Logger, :info => nil, :debug => nil) }

    before do
      Howler::Config[:concurrency] = 3

      @workers = 3.times.collect do
        mock(Howler::Worker, :perform! => nil)
      end

      subject.wrapped_object.stub(:build_workers).and_return(@workers)
      subject.wrapped_object.stub(:done?).and_return(false, true)
      subject.wrapped_object.instance_variable_set(:@logger, logger)
      logger.stub(:log).and_yield(log)
    end

    describe "when there are no messages" do
      it "should not log" do
        log.should_not_receive(:info)

        subject.run
      end
    end

    describe "when there are messages" do
      before do
        [:send_notification, :enforce_avgs].each_with_index do |method, i|
          subject.push(Array, method, [i, ((i+1)*100).to_s(36)])
        end
      end

      describe "information" do
        before do
          Howler::Config[:log] = 'info'
        end

        it "should log the number of messages to be processed" do
          log.should_receive(:info).with("Processing 2 Messages")

          subject.run
        end
      end

      describe "debug" do
        before do
          Howler::Config[:log] = 'debug'
        end

        it "should show a digest of the messages" do
          log.should_receive(:debug).with('MESG - 123 Array.new.send_notification(0, "2s")')
          log.should_receive(:debug).with('MESG - 123 Array.new.enforce_avgs(1, "5k")')

          subject.run
        end
      end
    end
  end

  describe "#done_chewing" do
    before do
      worker = mock(Howler::Worker)
      @chewing_worker = mock(Howler::Worker, :alive? => true)

      subject.wrapped_object.stub(:build_workers).and_return([worker])
      subject.wrapped_object.instance_variable_set(:@chewing, [@chewing_worker])

    end

    it "should remove the worker from chewing" do
      subject.chewing.should include(@chewing_worker)

      subject.done_chewing(@chewing_worker)

      subject.chewing.should_not include(@chewing_worker)
    end

    it "should make the worker available" do
      subject.workers.should_not include(@chewing_worker)

      subject.done_chewing(@chewing_worker)

      subject.workers.should include(@chewing_worker)
    end

    describe "when a worker has died" do
      before do
        @chewing_worker.stub(:alive?).and_return(false)
      end

      it "should make in un-available" do
        subject.chewing.should include(@chewing_worker)

        subject.done_chewing(@chewing_worker)

        subject.chewing.should_not include(@chewing_worker)
        subject.workers.should_not include(@chewing_worker)
      end
    end
  end

  describe "#worker_death" do
    before do
      subject.wrapped_object.stub(:done?).and_return(true)

      worker = mock(Howler::Worker)
      @chewing_worker = mock(Howler::Worker)
      @chewing_workers = [@chewing_worker]

      subject.wrapped_object.stub(:build_workers).and_return([worker])
      subject.wrapped_object.instance_variable_set(:@chewing, @chewing_workers)

      Howler::Config[:concurrency] = 3
      subject.run
    end

    describe "when the worker is alive" do
      before do
        @chewing_worker.stub(:alive?).and_return(true)
      end

      it "should create a new worker" do
        Howler::Worker.should_receive(:new_link)

        subject.worker_death
      end

      it "should add a worker" do
        subject.should have(1).workers

        subject.worker_death

        subject.should have(2).workers
      end

      it "should make in un-available" do
        @chewing_workers.should_receive(:delete).with(@chewing_worker)

        subject.worker_death(@chewing_worker)
      end
    end
  end

  describe "#shutdown" do
    before do
      subject.wrapped_object.stub(:done?).and_return(true)

      Howler::Config[:concurrency] = 2
      subject.wrapped_object.instance_variable_set(:@chewing, [mock(Howler::Worker)])
    end

    it "should not accept more work" do
      subject.wrapped_object.unstub(:done?)
      subject.should_not be_done

      subject.shutdown

      subject.should be_done
    end

    it "should remove non active workers from the list" do
      subject.run

      subject.should have(2).workers
      subject.should have(1).chewing

      subject.shutdown.should == 2

      subject.should have(0).workers
      subject.should have(1).chewing
    end
  end

  describe "#push" do
    let!(:queue) { Howler::Queue.new(Howler::Manager::DEFAULT) }

    def create_message(klass, method, args)
      {
        :id => 123,
        :class => klass.to_s,
        :method => method,
        :args => args,
        :created_at => Time.now.to_f
      }
    end

    before do
      Howler::Queue.stub(:new).and_return(queue)
    end

    describe "when given a class, method, and name" do
      it "should push a message" do
        Timecop.freeze(DateTime.now) do
          message = create_message("Array", :length, [1234])
          queue.should_receive(:push).with(message, Time.now)

          subject.push(Array, :length, [1234])
        end
      end

      it "should enqueue the message" do
        should_change(Howler::Manager::DEFAULT).length_by(1) do
          subject.push(Array, :length, [])
        end
      end
    end

    describe "when given the 'wait until' time" do
      it "should enqueue the message" do
        should_change(Howler::Manager::DEFAULT).length_by(1) do
          subject.push(Array, :length, [], Time.now + 5.minutes)
        end
      end
    end
  end
end
