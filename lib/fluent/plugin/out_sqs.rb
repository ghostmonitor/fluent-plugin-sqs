module Fluent

    require 'aws-sdk'

    SQS_BATCH_SEND_MAX_MSGS = 10
    SQS_BATCH_SEND_MAX_SIZE = 262144

    class SQSOutput < BufferedOutput
        Fluent::Plugin.register_output('sqs', self)

        include SetTagKeyMixin
        config_set_default :include_tag_key, false

        include SetTimeKeyMixin
        config_set_default :include_time_key, true

        config_param :aws_key_id, :string, :default => nil, :secret => true
        config_param :aws_sec_key, :string, :default => nil, :secret => true
        config_param :queue_name, :string
        config_param :create_queue, :bool, :default => true
        config_param :sqs_endpoint, :string, :default => 'sqs.ap-northeast-1.amazonaws.com'
        config_param :delay_seconds, :integer, :default => 0
        config_param :include_tag, :bool, :default => true
        config_param :tag_property_name, :string, :default => '__tag'

        def configure(conf)
            super
        end

        def start
            super

            @client = Aws::SQS::Client.new(
                :access_key_id => @aws_key_id,
                :secret_access_key => @aws_sec_key,
                :endpoint => @sqs_endpoint
            )

            if @create_queue then
                @queue_url = @client.create_queue(queue_name: @queue_name).queue_url
            else
                @queue_url = @client.get_queue_url(queue_name: @queue_name).queue_url
            end
        end

        def shutdown
            super
        end

        def format(tag, time, record)
            if @include_tag then
                record[@tag_property_name] = tag
            end

            record.to_msgpack
        end

        def write(chunk)
            batch_records = []
            batch_size = 0
            send_batches = [batch_records]

            chunk.msgpack_each do |record|
                body = Yajl.dump(record)
                batch_size += body.bytesize
                if batch_size > SQS_BATCH_SEND_MAX_SIZE ||
                        batch_records.length >= SQS_BATCH_SEND_MAX_MSGS then
                    batch_records = []
                    batch_size = body.bytesize
                    send_batches << batch_records
                end

                if batch_size > SQS_BATCH_SEND_MAX_SIZE then
                    log.warn "Could not push message to SQS, payload exceeds "\
                        "#{SQS_BATCH_SEND_MAX_SIZE} bytes.  "\
                        "(Truncated message: #{body[0..200]})"
                else
                    batch_records << { :message_body => body, :delay_seconds => @delay_seconds }
                end
            end

            until send_batches.length <= 0 do
                records = send_batches.shift
                until records.length <= 0 do
                    @client.send_message_batch(queue_url: @queue_url, entries: records.slice!(0..9))
                end
            end
        end
    end
end
