module Howler
  class Message::Notify < Message::Error
    attr_reader :cause, :env

    def initialize(cause, options = {})
      super(options)

      @cause = cause
      @env = {
        'hostname' => `hostname`.chomp,
        'ruby_version' => `ruby -v`.chomp
      }
    end

    def to_s(*)
      "Exception from #{@env['hostname']}\n\n#{backtrace.join("\n")}"
    end
  end
end
