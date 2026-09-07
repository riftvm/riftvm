#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
ruby -rjson -e '
  catalog = JSON.parse(File.read(ARGV.fetch(0)))
  abort "source language must be English" unless catalog["sourceLanguage"] == "en"
  catalog.fetch("strings").each do |key, entry|
    languages = entry.fetch("localizations", {}).keys
    abort "unexpected localization for #{key.inspect}" unless (languages - ["en"]).empty?
  end
' "$project_root/RiftVM/RiftVM/Localizable.xcstrings"
echo "Verified English-only String Catalog."
