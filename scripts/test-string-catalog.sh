#!/bin/bash

set -euo pipefail

# Ruby reads a -e script in the locale's encoding, so a non-ASCII character in
# one of the checks below is a syntax error when LANG is unset.
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

project_root="$(cd "$(dirname "$0")/.." && pwd)"
catalog="$project_root/RiftVM/RiftVM/Localizable.xcstrings"

ruby -rjson -e '
  catalog = JSON.parse(File.read(ARGV.fetch(0)))
  abort "the app must use English source strings" unless catalog.fetch("sourceLanguage") == "en"
  strings = catalog.fetch("strings")
  format_tokens = /%(?:\d+\$)?(?:lld|llu|ld|lu|[duf@])/ 

  strings.each do |key, entry|
    languages = entry.fetch("localizations", {}).keys
    abort "non-English localization for #{key.inspect}" unless (languages - ["en"]).empty?
    value = entry.dig("localizations", "en", "stringUnit", "value")
    next unless value

    source_tokens = key.scan(format_tokens).map { |token| token.sub(/%\d+\$/, "%") }.sort
    translated_tokens = value.scan(format_tokens).map { |token| token.sub(/%\d+\$/, "%") }.sort
    abort "placeholder mismatch for #{key.inspect}" unless source_tokens == translated_tokens
  end

  required = [
    "Preparing %@",
    "Preparing snapshot…",
    "Estimating restore storage…",
    "Preparing restore…",
    "Restoring snapshot \"%@\"…",
    "Snapshot \"%@\" restored",
    "Auditing snapshot integrity…",
    "Snapshot audit cancelled",
    "Inspecting snapshot storage…",
    "Cleaning snapshot storage…",
    "Preparing and checking available space",
    "Copying machine data",
    "Verifying snapshot integrity",
    "Installing the verified transaction",
    "Cancellation requested. RiftVM will stop at the next safe boundary.",
    "Protecting snapshot \"%@\"…",
    "Unprotecting snapshot \"%@\"…",
    "Shared Folders",
    "Create Snapshot",
    "Snapshots",
    "Export Diagnostics…",
    "Save State and Stop",
    "Delete snapshot \"%@\"? This cannot be undone.",
    "Snapshot \"%@\" created",
    "Snapshot \"%@\" deleted",
    "The virtual machine is running. Shut it down before creating or restoring snapshots.",
    "RiftVM will keep a recovery point before replacing the machine state.",
    "· %lld snapshots · %@",
    "Version %@ (%@)",
    "Copied",
    "Copy Error",
    "Report on GitHub…",
    "Opens a prefilled GitHub issue for you to review and submit."
  ]

  required.each do |key|
    abort "missing required English string: #{key.inspect}" unless strings.key?(key)
  end
' "$catalog"

echo "Verified English-only String Catalog keys and format placeholders."
