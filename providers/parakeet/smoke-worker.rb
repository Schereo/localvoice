require "base64"
require "json"
require "open3"
require "timeout"

abort "Usage: ruby smoke-worker.rb <worker> <v3|ultra|redux|nemotron> <model directory> <pcm.f32> <expected phrase> [de|en|auto]" unless (5..6).include?(ARGV.length)
worker, variant, models, audio, expected, language = ARGV
language ||= "auto"
abort "Expected language de, en, or auto" unless %w[de en auto].include?(language)
pcm = File.binread(audio, 30 * 16_000 * 4 + 1)
abort "Expected up to 30 seconds of raw float32 mono 16 kHz PCM" if pcm.empty? || pcm.bytesize > 30 * 16_000 * 4 || pcm.bytesize % 4 != 0

request = JSON.generate(pcm: Base64.strict_encode64(pcm))
normalize = ->(text) { text.downcase.scan(/[[:alnum:]]+/).join(" ") }
phrase = normalize.call(expected)
abort "Expected phrase must contain words" if phrase.empty?
read_event = ->(output, seconds) { JSON.parse(Timeout.timeout(seconds) { output.readline }) }

Open3.popen3("/usr/bin/sandbox-exec", "-p", "(version 1) (allow default) (deny network*)",
             File.expand_path(worker), variant, File.expand_path(models)) do |input, output, errors, process|
  begin
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ready = read_event.call(output, 110)
    raise "Worker did not become ready: #{ready.fetch("error", ready.fetch("event"))}" unless ready == {"event" => "ready"}
    puts format("ready %.2fs", Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)

    input.puts("invalid JSON")
    raise "Malformed request was not rejected" unless read_event.call(output, 5)["event"] == "error"

    send_request = lambda do |json, timeout = 45|
      reply = JSON.parse(Timeout.timeout(timeout) do
        input.puts(json)
        output.readline
      end)
      raise "Worker returned #{reply.fetch("event")}, not a result" unless reply["event"] == "result"
      reply.fetch("text")
    end

    2.times do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if variant == "nemotron"
        raise "Start did not return an empty result" unless send_request.call(JSON.generate(command: "start", language: language)).empty?
        window_bytes = 35_840 * 4
        heard_partial = false
        (0...pcm.bytesize).step(window_bytes) do |offset|
          payload = Base64.strict_encode64(pcm.byteslice(offset, window_bytes))
          partial = send_request.call(JSON.generate(command: "chunk", pcm: payload))
          heard_partial ||= !partial.strip.empty?
        end
        raise "No speech recognized before finish" unless heard_partial
        text = send_request.call(JSON.generate(command: "finish"))
      else
        text = send_request.call(request)
      end
      raise "Transcription did not match the expected phrase" unless normalize.call(text).include?(phrase)
      puts format("matched phrase %.2fs", Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
    end

    input.close
    raise "Extra protocol output or unexpected stderr" unless Timeout.timeout(5) { output.read.empty? && errors.read.empty? }
    raise "Worker did not exit cleanly" unless Timeout.timeout(5) { process.value.success? }
  ensure
    begin
      Process.kill("KILL", process.pid) if process.alive?
    rescue Errno::ESRCH
      # The child exited between the liveness check and kill.
    end
  end
end
