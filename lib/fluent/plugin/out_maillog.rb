module Fluent
  class MaillogOutput < Output
    Plugin.register_output('maillog', self)

    config_param :tag,                 :string,  :default => nil
    config_param :cache_dump_file,     :string,  :default => nil
    config_param :clean_interval_time, :integer, :default => 60
    config_param :lifetime,            :integer, :default => 3600
    config_param :revise_time,         :bool,    :default => true
    config_param :field,               :string,  :default => 'message'

    attr_accessor :records
    attr_accessor :revise_time
    attr_reader   :latest_clean_time

    def initialize
      super
      @records = Hash.new
      @latest_clean_time = Time.now.to_i
    end

    def configure(conf)
      super

      raise "Required config_param is missing: tag" if @tag.nil?

      @prefix_ptn = /^(?<time>.{3}\s{1,2}\d{1,2} \d{2}:\d{2}:\d{2}) (?<host>\S+) (?<cmd>.+)\[\d+\]: (?<qid>[0-9a-zA-Z]+): (?<message>.+)$/
      @store_ptns = [
        /^client=.+$/,
        /^message-id=<(?<message_id>[^,]+)>$/,
        /^from=<(?<from>[^,]+)>, size=(?<size>[0-9]+), nrcpt=(?<nrcpt>[0-9]+).*$/
#        /^DKIM-Signature field added \(s=(?<dkim_s>[^,]+), d=(?<dkim_d>[^,]+)\)$/
      ]
      @emit_ptns = [
        /^to=<(?<to>[^,]+)>, relay=(?<relay>[^ ]+), delay=(?<delay>[^ ]+), delays=(?<delays>[^ ]+), dsn=(?<dsn>[^ ]+), status=(?<status>[^ ]+) \((?<message>.+)\)$/
      ]
      @clear_ptns = [
        /^removed$/
      ]
    end

    def start
      super
      @records = read_cache_dump_file
      @interrupted_qid = @records.keys
      $log.debug "[maillog] read qid : #{@interrupted_qid}" if @interrupted_qid.size > 0
    end

    def shutdown
      write_cache_dump_file
      super
    end

    def emit(tag, es, chain)
      es.each do |time, record|
        summary = summarize(record[@field])
        next if summary.nil?
        Fluent::Engine.emit(@tag, time, summary)
        if @interrupted_qid.include?(summary['qid'])
          $log.debug "[maillog] #{summary['qid']} : emit"
        end
      end
      chain.next
    end

    def summarize(line)
      if @prefix_ptn =~ line
        qid     = Regexp.last_match[:qid]
        time    = Regexp.last_match[:time]
        message = Regexp.last_match[:message]
        return nil if qid.nil? || time.nil?
        record = @records[qid]
        if record.nil?
          record = { 'qid' => qid, 'time' => revised_time(time).to_i }
          @records.store(qid, record)
        end
        $log.debug "[maillog] #{qid} : #{message}" if @interrupted_qid.include?(qid)
        # regist
        @store_ptns.each do |ptn|
          if ptn =~ message
            ptn.named_captures.keys.each do |name|
              record[name] = Regexp.last_match[name.to_sym]
            end
            return nil
          end
        end
        # emit
        @emit_ptns.each do |ptn|
          if ptn =~ message
            ptn.named_captures.keys.each do |name|
              record[name] = Regexp.last_match[name.to_sym]
            end
            record['time'] = revised_time(time).to_i
            return record
          end
        end
        # remove
        @clear_ptns.each do |ptn|
          if ptn =~ message
            @records.delete(qid)
          end
        end
      end
      clean_record_cache
      return nil
    end

    def revised_time(time)
      t = Time.parse(time)
      return Time.parse("#{t.year - 1}-#{t.strftime("%m-%d %H:%M:%S")}") if @revise_time && t > Time.now
      return t
    end

    def clean_record_cache(clean_interval_time = @clean_interval_time, lifetime = @lifetime)
      return if Time.now.to_i < @latest_clean_time + clean_interval_time
      cnt = @records.length
      @records.delete_if do |key, record|
        Time.now.to_i > record['time'] + lifetime
      end
      @latest_clean_time = Time.now.to_i
      # logging
      del_cnt = cnt - @records.length
      next_time = Time.at(@latest_clean_time + clean_interval_time)
      $log.info "[maillog] cleaned record cache : { count => #{del_cnt}, next_time => #{next_time} }"
    end

    def read_cache_dump_file(cache_dump_file = @cache_dump_file)
      return Hash.new if cache_dump_file.nil?
      return Hash.new if !FileTest.exists?(cache_dump_file)
      h = JSON.parse(File.read(cache_dump_file, :encoding => Encoding::UTF_8))
      $log.info "[maillog] imported cache dump file : { file => #{cache_dump_file}, count => #{h.length} }"
      File.unlink cache_dump_file
      $log.info "[maillog] removed cache dump file : { file => #{cache_dump_file} }"
      return h
    end

    def write_cache_dump_file(cache_dump_file = @cache_dump_file, records = @records)
      return if cache_dump_file.nil?
      if records.length > 0
        File.write(cache_dump_file, records.to_json)
        $log.info "[maillog] exported chach dump file : { file => #{cache_dump_file}, count => #{records.length} }"
        $log.debug "[maillog] dump qid : #{records.keys}"
      end
    end
  end
end
