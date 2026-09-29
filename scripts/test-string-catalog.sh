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
  strings = catalog.fetch("strings")
  format_tokens = /%(?:\d+\$)?(?:lld|llu|ld|lu|[duf@])/ 

  strings.each do |key, entry|
    value = entry.dig("localizations", "zh-Hans", "stringUnit", "value")
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
    "Version %@ (%@)"
  ]

  required.each do |key|
    unit = strings.dig(key, "localizations", "zh-Hans", "stringUnit")
    abort "missing required translation: #{key.inspect}" unless unit&.fetch("state", nil) == "translated"
    abort "empty required translation: #{key.inspect}" if unit.fetch("value", "").strip.empty?
  end
' "$catalog"

echo "Verified String Catalog placeholders and core runtime translations."
