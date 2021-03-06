require 'fluent/plugin/input'
require 'aws-sdk-sqs'
require 'json'

module Fluent::Plugin
  class SQSInput < Input
    Fluent::Plugin.register_input('sqs', self)

    helpers :timer

    config_param :aws_key_id, :string, default: nil, secret: true
    config_param :aws_sec_key, :string, default: nil, secret: true
    config_param :tag, :string
    config_param :tag_key, :string, default: nil
    config_param :region, :string, default: 'ap-northeast-1'
    config_param :sqs_url, :string, default: nil
    config_param :receive_interval, :time, default: 0.1
    config_param :max_number_of_messages, :integer, default: 10
    config_param :wait_time_seconds, :integer, default: 10
    config_param :visibility_timeout, :integer, default: nil
    config_param :delete_message, :bool, default: false
    config_param :stub_responses, :bool, default: false
    config_param :raw_message, :bool, default: false

    def configure(conf)
      super

      Aws.config = {
        access_key_id: @aws_key_id,
        secret_access_key: @aws_sec_key,
        region: @region
      }
    end

    def start
      super

      timer_execute(:in_sqs_run_periodic_timer, @receive_interval, &method(:run))
    end

    def client
      @client ||= Aws::SQS::Client.new(stub_responses: @stub_responses)
    end

    def queue
      @queue ||= Aws::SQS::Resource.new(client: client).queue(@sqs_url)
    end

    def shutdown
      super
    end

    def run
      queue.receive_messages(
        max_number_of_messages: @max_number_of_messages,
        wait_time_seconds: @wait_time_seconds,
        visibility_timeout: @visibility_timeout
      ).each do |message|
        record = @raw_message ? parse_raw_message(message) : parse_message(message)

        message.delete if @delete_message

        tag = @tag_key ? record[@tag_key] : @tag
        record.delete @tag_key if @tag_key

        log.debug "emiting record under tag #{tag}: #{record.to_s}"
        router.emit(tag, Fluent::Engine.now, record)
      end
    rescue
      log.error 'failed to emit or receive', error: $ERROR_INFO.to_s, error_class: $ERROR_INFO.class.to_s
      log.warn_backtrace $ERROR_INFO.backtrace
    end

    private

    def get_tag_name(record)
      record[@tag_key] rescue @tag
    end

    def parse_raw_message(message)
      JSON.parse(message.body) rescue message.body.to_s
    end

    def parse_message(message)
      {
        'body' => message.body.to_s,
        'receipt_handle' => message.receipt_handle.to_s,
        'message_id' => message.message_id.to_s,
        'md5_of_body' => message.md5_of_body.to_s,
        'queue_url' => message.queue_url.to_s,
        'sender_id' => message.attributes['SenderId'].to_s
      }
    end
  end
end
