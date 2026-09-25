namespace :fetcher do
  desc "DIR/*.xml から Rust製fetcher用の golden (DIR/<name>.golden.json) を生成する"
  task :golden, [ :dir ] => :environment do |_task, args|
    dir = Pathname(args.fetch(:dir))
    dir.glob("*.xml").sort.each do |xml_path|
      name = xml_path.basename(".xml").to_s
      url_path = dir.join("#{name}.url")
      feed_url = url_path.exist? ? url_path.read.lines.first.strip : "https://example.com/#{name}/feed.xml"

      result = FetcherGolden.build(body: xml_path.binread, feed_url:)
      dir.join("#{name}.golden.json").write(JSON.pretty_generate(result) + "\n")
      puts "wrote #{name}.golden.json (#{result[:entries].size} entries, #{result[:skipped].size} skipped)"
    rescue StandardError => e
      puts "FAILED #{name}: #{e.class}: #{e.message}"
    end
  end
end
