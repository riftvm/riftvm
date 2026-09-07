#!/usr/bin/env ruby

require "digest"
require "fileutils"

version, archive_path, template_path, output_path = ARGV
abort "usage: update-cask.rb <version> <archive> <template> <output>" unless ARGV.length == 4
version = version.delete_prefix("v")
abort "invalid release version" unless version.match?(/\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\z/)
abort "archive must be a regular file" unless File.file?(archive_path) && !File.symlink?(archive_path)
content = File.read(template_path)
%w[@VERSION@ @SHA256@].each do |token|
  abort "template must contain exactly one #{token}" unless content.scan(token).length == 1
end
sha256 = Digest::SHA256.file(archive_path).hexdigest
content = content.sub("@VERSION@", version).sub("@SHA256@", sha256)
FileUtils.mkdir_p(File.dirname(output_path))
File.write(output_path, content)
puts "Generated RiftVM #{version} cask (#{sha256})"
