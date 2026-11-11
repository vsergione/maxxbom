# bridge.rb — Dev-only command folder. SketchUp polls inbox/*.rb on the UI
# thread and writes outbox/<id>.json. The repo and SketchUp share this tree
# (Z:\maxxbom). A command is written as .tmp, then renamed to .rb.

require "fileutils"
require "json"
require "stringio"

module Logimaxx
  module MaxxBOM
    module Bridge
      INTERVAL = 0.5

      def self.root_dir
        File.expand_path("..", ROOT)
      end

      def self.inbox_dir
        File.join(root_dir, "bridge", "inbox")
      end

      def self.outbox_dir
        File.join(root_dir, "bridge", "outbox")
      end

      def self.start
        stop
        FileUtils.mkdir_p(inbox_dir)
        FileUtils.mkdir_p(outbox_dir)
        @timer = ::UI.start_timer(INTERVAL, true) { poll }
        puts "[MaxxBOM] Bridge watching #{inbox_dir}"
      end

      def self.stop
        timer = @timer
        @timer = nil
        return unless timer
        ::UI.stop_timer(timer)
      rescue StandardError
        nil
      end

      def self.poll
        return if @busy
        @busy = true
        Dir.glob(File.join(inbox_dir, "*.rb")).sort.each { |path| run(path) }
      rescue StandardError => e
        puts "[MaxxBOM] bridge poll failed: #{e.class}: #{e.message}"
      ensure
        @busy = false
      end

      def self.run(path)
        id = File.basename(path, ".rb")
        processing = "#{path}.run"
        begin
          File.rename(path, processing)
        rescue Errno::EACCES, Errno::EPERM, Errno::EBUSY
          return
        end

        source = File.read(processing, encoding: "UTF-8")
        stdout = StringIO.new
        stdout.set_encoding("UTF-8")
        error = nil
        returned = nil
        old_stdout = $stdout
        $stdout = stdout
        begin
          returned = eval(source, TOPLEVEL_BINDING, path, 1)
        rescue StandardError => e
          error = "#{e.class}: #{e.message}\n#{Array(e.backtrace).first(12).join("\n")}"
          begin
            Sketchup.active_model.abort_operation
          rescue StandardError
            nil
          end
        ensure
          $stdout = old_stdout
        end
        File.delete(processing) if File.exist?(processing)
        write_result(id, {
          "ok" => error.nil?,
          "stdout" => stdout.string,
          "error" => error,
          "value" => json_safe(returned)
        })
      rescue StandardError => e
        puts "[MaxxBOM] bridge run failed: #{e.class}: #{e.message}"
      end

      def self.json_safe(value)
        JSON.parse(JSON.generate(value))
      rescue StandardError
        value.nil? ? nil : value.to_s
      end

      def self.write_result(id, payload)
        dest = File.join(outbox_dir, "#{id}.json")
        tmp = "#{dest}.tmp"
        File.write(tmp, JSON.pretty_generate(payload), encoding: "UTF-8")
        File.rename(tmp, dest)
      end
    end
  end
end
