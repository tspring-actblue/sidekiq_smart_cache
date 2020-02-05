module SidekiqSmartCache
  class Promise
    attr_accessor :klass, :object_param, :method, :expires_in, :args, :job_interlock_timeout
    attr_accessor :timed_out, :value
    delegate :redis, :log, :cache_prefix, to: SidekiqSmartCache
    delegate :working?, to: :interlock

    def initialize(klass: nil, object: nil, object_param: nil, method:, args: nil,
                   cache_tag: nil, expires_in: 1.hour, job_interlock_timeout: nil)
      if object
        @klass = object.class.name
        @object_param = object.to_param
      elsif klass
        @klass = klass
        @object_param = object_param
      else
        raise "Must provide either klass or object"
      end
      raise "Must provide method" unless method
      @method = method
      @expires_in = expires_in.to_i
      @job_interlock_timeout = job_interlock_timeout || @expires_in
      @args = args
      @cache_tag = cache_tag
    end

    def cache_tag
      @cache_tag ||= begin
        [
          cache_prefix,
          klass,
          (object_param || '.'),
          method,
          (Digest::MD5.hexdigest(args.compact.to_json) if args.present?)
        ].compact * '/'
      end
    end

    def interlock
      @_interlock ||= Interlock.new(cache_tag, job_interlock_timeout)
    end

    def enqueue_job!
      Worker.perform_async(klass, object_param, method, args, cache_tag, expires_in)
    end

    def execute_and_wait!(timeout)
      execute_and_wait(timeout, raise_on_timeout: true)
    end

    def existing_value
      @value ||= redis.get(cache_tag)
    end

    def ready_within?(timeout)
      execute_and_wait(timeout)
      !timed_out
    end

    def timed_out?
      !!timed_out
    end

    def start
      # Start a job if no other client has
      if interlock.lock_job?
        log('promise enqueuing calculator job')
        enqueue_job!
      else
        log('promise calculator job already working')
      end
    end

    def execute_and_wait(timeout, raise_on_timeout: false)
      return value unless timed_out.nil?
      found_message = existing_value
      if found_message
        # found a previously fresh message
        @timed_out = false
        return found_message
      else
        start

        # either a job was already running or we started one, now wait for an answer
        if redis.wait_for_done_message(cache_tag, timeout.to_i)
          # ready now, fetch it
          log('promise calculator job finished')
          @timed_out = false
          existing_value
        else
          log('promise timed out awaiting calculator job')
          @timed_out = true
          raise TimeoutError if raise_on_timeout
        end
      end
    end
  end
end
