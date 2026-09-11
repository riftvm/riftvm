#!/bin/bash

set -euo pipefail

# Contract test for the Linux system-image catalog.
#
# Three copies of the same data must stay identical:
#   1. the published endpoint the app refreshes from (riftvm.com/catalog/linux.json)
#   2. docs/catalog/linux.json — the maintained source for that endpoint
#   3. VMSystemImageCatalog.linuxItems — the app's offline fallback
#
# The app shipped this wrong once: it pointed at a retired host that answered 404,
# so the online catalog could never refresh, and the fallback still listed releases
# that the published catalog had already replaced. This test fails on any drift.

project_root="$(cd "$(dirname "$0")/.." && pwd)"
catalog_file="${RIFTVM_CATALOG_FILE:-$project_root/RiftVM/RiftVM/Core/VMKit/Catalog/VMSystemImageCatalog.swift}"
docs_catalog="${RIFTVM_CATALOG_SOURCE:-$project_root/docs/catalog/linux.json}"
canonical_endpoint="https://riftvm.com/catalog/linux.json"
expected_hosts="cdimage.ubuntu.com cdimage.debian.org download.fedoraproject.org"

fail() { echo "test-linux-catalog: $*" >&2; exit 1; }

[[ -f "$catalog_file" ]] || fail "catalog source not found: $catalog_file"
[[ -f "$docs_catalog" ]] || fail "catalog JSON not found: $docs_catalog"

ruby -rjson -e '
  catalog_file, docs_catalog, canonical_endpoint, expected_hosts = ARGV
  source = File.read(catalog_file)
  docs = JSON.parse(File.read(docs_catalog))
  errors = []

  # --- 1. The refresh endpoint must be the canonical published URL ---
  endpoints = source.scan(/private static let endpoint = URL\(string: "([^"]+)"\)!/)
  linux_endpoints = endpoints.flatten.select { |url| url.end_with?("/catalog/linux.json") }
  errors << "expected exactly one Linux catalog endpoint, found #{linux_endpoints.length}" unless linux_endpoints.length == 1
  if linux_endpoints.length == 1 && linux_endpoints.first != canonical_endpoint
    errors << "Linux catalog endpoint is #{linux_endpoints.first}, expected #{canonical_endpoint}"
  end
  if source.include?("everettjf.github.io")
    errors << "catalog source still references the retired everettjf.github.io host"
  end

  # --- 2. Host allowlist must match the hosts the catalog actually uses ---
  allowlist = source[/allowedDownloadHosts: Set<String> = \[(.*?)\]/m, 1].to_s
  hosts = allowlist.scan(/"([^"]+)"/).flatten.sort
  expected = expected_hosts.split(" ").sort
  errors << "allowed download hosts are #{hosts.inspect}, expected #{expected.inspect}" unless hosts == expected

  # --- 3. docs/catalog/linux.json contract ---
  images = docs["images"]
  errors << "catalog JSON has no images array" unless images.is_a?(Array) && !images.empty?
  if images.is_a?(Array)
    ids = images.map { |image| image["id"] }
    errors << "catalog JSON has duplicate ids: #{ids.inspect}" unless ids.uniq.length == ids.length
    images.each do |image|
      id = image["id"]
      errors << "catalog entry without a non-empty id" unless id.is_a?(String) && !id.empty?
      %w[name url].each do |field|
        value = image[field]
        errors << "catalog entry #{id.inspect} has no #{field}" unless value.is_a?(String) && !value.empty?
      end
      url = image["url"].to_s
      errors << "catalog entry #{id.inspect} is not an https URL: #{url}" unless url.start_with?("https://")
      host = url[/\Ahttps:\/\/([^\/]+)/, 1].to_s.downcase
      errors << "catalog entry #{id.inspect} uses host #{host.inspect}, outside the allowlist" unless expected.include?(host)
      errors << "catalog entry #{id.inspect} does not point at an .iso: #{url}" unless url.downcase.end_with?(".iso")
      version = image["version"]
      errors << "catalog entry #{id.inspect} has no version" unless version.is_a?(String) && !version.empty?
      size = image["fileSize"]
      errors << "catalog entry #{id.inspect} has no positive fileSize" unless size.is_a?(Integer) && size.positive?
      digest = image["sha256"]
      unless digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/)
        errors << "catalog entry #{id.inspect} has no lowercase 64-character sha256"
      end
    end
  end

  # --- 4. Built-in fallback must equal the catalog entry for entry ---
  # Each built-in item is one VMSystemImageCatalogItem(...) call whose fields are
  # either "key: value," literals or "urlString:" for the URL.
  # `struct`/`let` declarations and `->` return types both contain the type name
  # followed by "(", so only count a call whose arguments start on the next line.
  # Parse only the `linuxItems` array so the model initializer and the macOS
  # factory cannot be mistaken for catalog entries.
  linux_block = source[/static let linuxItems[^\n]*\[(.*?)\n    \]/m, 1].to_s
  errors << "could not locate the built-in linuxItems array" if linux_block.empty?
  items = linux_block.scan(/\bVMSystemImageCatalogItem\(\n(.*?)\n        \)/m).flatten
  items = items.select { |body| body.include?("osType: .linux") }
  errors << "no built-in Linux catalog items were parsed" if items.empty?
  built_in = {}
  items.each do |body|
    id = body[/\bid: "([^"]+)"/, 1]
    unless id
      errors << "built-in item without an id"
      next
    end
    errors << "built-in item #{id.inspect} appears twice" if built_in.key?(id)
    built_in[id] = {
      "name" => body[/\bname: "([^"]*)"/, 1],
      "url" => body[/urlString: "([^"]+)"/, 1],
      "version" => body[/\bversion: "([^"]*)"/, 1],
      "fileSize" => body[/\bfileSize: ([0-9_]+)/, 1]&.delete("_")&.to_i,
      "sha256" => body[/\bsha256: "([^"]*)"/, 1],
    }
  end

  if images.is_a?(Array)
    catalog_by_id = images.to_h { |image| [image["id"], image] }
    missing = catalog_by_id.keys - built_in.keys
    extra = built_in.keys - catalog_by_id.keys
    errors << "catalog entries missing from the built-in fallback: #{missing.inspect}" unless missing.empty?
    errors << "built-in fallback has entries absent from the catalog: #{extra.inspect}" unless extra.empty?
    catalog_by_id.each do |id, image|
      item = built_in[id]
      next unless item
      {
        "name" => image["name"],
        "url" => image["url"],
        "version" => image["version"],
        "fileSize" => image["fileSize"],
        "sha256" => image["sha256"],
      }.each do |field, expected_value|
        next if item[field] == expected_value
        errors << "built-in #{id.inspect} #{field} is #{item[field].inspect}, catalog says #{expected_value.inspect}"
      end
    end
  end

  if errors.empty?
    puts "Verified Linux catalog endpoint, source JSON, and built-in fallback for #{built_in.length} images."
  else
    errors.each { |error| warn "test-linux-catalog: #{error}" }
    exit 1
  end
' "$catalog_file" "$docs_catalog" "$canonical_endpoint" "$expected_hosts"

# The recursive invocations below verify mutations, so they must not re-enter
# the mutation cases themselves.
if [[ "${RIFTVM_CATALOG_CONTRACT_ONLY:-0}" == "1" ]]; then
  exit 0
fi

# --- The contract test must fail on real drift -------------------------------
# Each case mutates a throwaway copy and requires a specific rejection, so a
# regression that neutralizes the checks above cannot pass silently.

work="$(mktemp -d "${TMPDIR:-/tmp}/riftvm-linux-catalog-test.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

mutated_swift="$work/VMSystemImageCatalog.swift"
mutated_docs="$work/linux.json"
patch_catalog() { ruby -rjson -e "$1" "$mutated_docs"; }
patch_swift() { ruby -e "$1" "$mutated_swift"; }
reset_fixtures() {
  cp "$catalog_file" "$mutated_swift"
  cp "$docs_catalog" "$mutated_docs"
}

run_contract() {
  RIFTVM_CATALOG_CONTRACT_ONLY=1 \
  RIFTVM_CATALOG_FILE="$mutated_swift" \
  RIFTVM_CATALOG_SOURCE="$mutated_docs" \
    "$0"
}

expect_rejection() {
  local description="$1" expected_message="$2"
  if run_contract >"$work/stdout" 2>"$work/stderr"; then
    fail "$description was accepted"
  fi
  grep -Fq "$expected_message" "$work/stderr" || {
    cat "$work/stderr" >&2
    fail "$description failed for an unexpected reason"
  }
}

# Unchanged copies must still pass through the same override path.
reset_fixtures
run_contract >/dev/null || fail "unmodified temporary copies did not pass"

cp "$mutated_swift" "$work/endpoint-backup"
patch_swift 'path = ARGV.fetch(0); body = File.read(path); body.sub!("https://riftvm.com/catalog/linux.json", "https://example.test/catalog/linux.json"); File.write(path, body)'
expect_rejection "a non-canonical catalog endpoint" "expected https://riftvm.com/catalog/linux.json"
cp "$work/endpoint-backup" "$mutated_swift"

patch_swift 'path = ARGV.fetch(0); body = File.read(path); body.sub!("https://riftvm.com/catalog/linux.json", "https://everettjf.github.io/riftvm/catalog/linux.json"); File.write(path, body)'
expect_rejection "the retired everettjf.github.io catalog host" "retired everettjf.github.io host"
cp "$work/endpoint-backup" "$mutated_swift"

patch_catalog 'docs = JSON.parse(File.read(ARGV.fetch(0))); docs["images"][2]["version"] = "13.1.0"; File.write(ARGV.fetch(0), JSON.pretty_generate(docs))'
expect_rejection "a stale Debian version" "built-in \"debian-13-netinst\" version"
reset_fixtures

patch_catalog 'docs = JSON.parse(File.read(ARGV.fetch(0))); docs["images"][2].delete("sha256"); File.write(ARGV.fetch(0), JSON.pretty_generate(docs))'
expect_rejection "a catalog entry without a checksum" "has no lowercase 64-character sha256"
reset_fixtures

patch_swift 'path = ARGV.fetch(0); body = File.read(path); body.sub!("            id: \"fedora-44-server\",\n", ""); File.write(path, body)'
expect_rejection "a built-in entry missing from the catalog" "missing from the built-in fallback"

echo "Verified Linux catalog contract, including drift rejection."

