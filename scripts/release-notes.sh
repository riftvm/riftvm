#!/bin/bash

set -euo pipefail

# Release notes helper.
#
#   prepare <version>   Add a draft note to docs/RELEASES.md when the release has
#                       none. Never touches a section that already exists, so a
#                       written note is safe. Used by the release scripts, which
#                       must not be blocked by a missing note.
#   extract <version>   Print the note as it should read on GitHub Releases.
#   check               Report release tags without a section. Never fails a
#                       release; for manual use.
#
# The note convention is documented at the top of docs/RELEASES.md.

project_root="$(cd "$(dirname "$0")/.." && pwd)"
notes_file="${RIFTVM_RELEASE_NOTES_FILE:-$project_root/docs/RELEASES.md}"
notes_repo="${RIFTVM_RELEASE_REPOSITORY:-riftvm/riftvm}"
notes_branch="${RIFTVM_RELEASE_BRANCH:-main}"
draft_marker="<!-- draft: generated from commits; replace with user-facing wording if the change needs it -->"

# RiftVM version tags that predate the notes convention.
exempt_tags=(
  riftvm-v0.1.0
  riftvm-v0.1.1
  riftvm-v0.1.2
  riftvm-v0.1.3
  riftvm-v0.1.5
  riftvm-v0.1.6
  riftvm-v0.1.7
  riftvm-v0.1.8
  riftvm-v0.1.9
  riftvm-v0.1.10
)

fail() { echo "release-notes: $*" >&2; exit 1; }

[[ -f "$notes_file" && ! -L "$notes_file" ]] || fail "release notes not found: $notes_file"

is_exempt() {
  local candidate="$1" exempt
  for exempt in "${exempt_tags[@]}"; do
    [[ "$candidate" == "$exempt" ]] && return 0
  done
  return 1
}

previous_tag() {
  git -C "$project_root" tag --list 'riftvm-v[0-9]*.[0-9]*.[0-9]*' --sort=version:refname \
    | awk -v want="$1" '$0 == want { print prev; exit } { prev = $0 }'
}

command="${1:-}"
version="${2#v}"

case "$command" in
  prepare)
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "usage: $0 prepare <major.minor.patch>"
    existing="$(awk -v heading="## $version" 'index($0, heading) == 1 { print "yes"; exit }' "$notes_file")"
    if [[ -n "$existing" ]]; then
      echo "Release notes for $version already exist."
      exit 0
    fi

    tag="riftvm-v$version"
    # The version being prepared has no tag yet, so the baseline is the latest
    # released tag below it. Comparing against the new tag itself would list the
    # entire history.
    if git -C "$project_root" rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
      range="$tag"
      base="$(previous_tag "$tag")"
    else
      range="HEAD"
      base="$(git -C "$project_root" tag --list 'riftvm-v[0-9]*.[0-9]*.[0-9]*' --sort=version:refname | tail -1)"
    fi
    # Read subject and body per commit so the generated changelog can use the
    # motivation lines the author already wrote, not only the subject.
    log_format='--format=%s%x1f%b%x1e'
    if [[ -n "$base" ]]; then
      commits="$(git -C "$project_root" log --no-merges "$log_format" "$base..$range" | tr -d '\r')"
    else
      commits="$(git -C "$project_root" log --no-merges "$log_format" "$range" | tr -d '\r')"
    fi

    RIFTVM_DRAFT_MARKER="$draft_marker" VERSION="$version" COMMITS="$commits" \
      ruby -e '
        path = ARGV.fetch(0)
        version = ENV.fetch("VERSION")
        marker = ENV.fetch("RIFTVM_DRAFT_MARKER")
        content = File.read(path)
        abort "release notes lost their convention section" unless content.include?("## How to write a release note")

        # Conventional-commit prefixes, in reading order. Everything else is a change.
        groups = [
          ["feat", "Features"],
          ["fix", "Fixes"],
          ["perf", "Performance"],
          ["refactor", "Internal"],
          ["chore", "Internal"],
          ["docs", "Documentation"],
          ["test", "Internal"],
          ["ci", "Internal"],
          ["build", "Internal"],
        ]

        bullets = Hash.new { |hash, key| hash[key] = [] }
        ENV.fetch("COMMITS", "").split("\x1e").each do |record|
          record = record.strip
          next if record.empty?
          subject, body = record.split("\x1f", 2)
          next if subject.nil? || subject.empty?
          next if subject.start_with?("Prepare RiftVM ")
          next if subject.include?("release note") && subject.start_with?("Record ")

          key = "Changes"
          text = subject
          if (match = subject.match(/\A([a-z]+)(?:\([^)]*\))?!?:\s*(.+)\z/)) && groups.any? { |prefix, _| prefix == match[1] }
            key = match[1]
            text = match[2]
          end
          text = text[0].upcase + text[1..] if text.length > 1

          # The commit body is soft-wrapped, so use its first sentence rather
          # than its first line, which is usually cut mid-sentence. Stop at the
          # first blank line so a bullet list in the body does not bleed in.
          first_paragraph = body.to_s.split(/\n[ \t]*\n/, 2).first.to_s
          body_text = first_paragraph.gsub(/\s+/, " ").strip
          detail = body_text.split(/(?<=\.)\s+(?=[A-Z])/).first
          detail = nil if detail && (detail.empty? || detail.length > 240)
          if detail
            detail = detail.sub(/\A[-*]\s*/, "")
            normalized_subject = subject.downcase.gsub(/[^a-z0-9]/, "")
            normalized_detail = detail.downcase.gsub(/[^a-z0-9]/, "")
            unless normalized_detail.empty? ||
                   normalized_subject.include?(normalized_detail) ||
                   normalized_detail.include?(normalized_subject)
              text = "#{text} — #{detail}"
            end
          end
          bullets[key] << text unless bullets[key].include?(text)
        end

        order = ["Changes"] + groups.map(&:first)
        section = ["## #{version}", "", marker, "", "Requires **macOS 27 or later and Apple silicon**."]
        wrote_any = false
        order.each do |key|
          items = bullets[key]
          next if items.empty?
          wrote_any = true
          title = groups.assoc(key)&.last || "Changes"
          section << ""
          section << "### #{title}"
          section << ""
          items.each { |item| section << "- #{item}" }
        end
        unless wrote_any
          section << ""
          section << "### Changes"
          section << ""
          section << "- <no source changes were found between the previous release and this one>"
        end
        section << ""
        section = section.join("\n")

        # Newest release first: insert before the first existing version heading.
        if content =~ /^## [0-9]+\.[0-9]+\.[0-9]+$/
          content = content.sub(/^(## [0-9]+\.[0-9]+\.[0-9]+$)/) { "#{section}\n#{$1}" }
        else
          content = content.rstrip + "\n\n" + section
        end
        File.write(path, content)
      ' "$notes_file"
    echo "Added a draft release note for $version to $(basename "$notes_file")."
    ;;

  extract)
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "usage: $0 extract <major.minor.patch>"
    RIFTVM_DRAFT_MARKER="$draft_marker" VERSION="$version" NOTES_REPO="$notes_repo" NOTES_BRANCH="$notes_branch" \
      ruby -e '
        path = ARGV.fetch(0)
        version = ENV.fetch("VERSION")
        marker = ENV.fetch("RIFTVM_DRAFT_MARKER")
        content = File.read(path)
        body = content[/^## #{Regexp.escape(version)}$\n(.*?)(?=^## |\z)/m, 1]
        abort "no release notes for #{version}" unless body
        body = body.sub(/\A\n+/, "").sub(/^#{Regexp.escape(marker)}\n/, "")
        base = "https://github.com/#{ENV.fetch("NOTES_REPO")}/blob/#{ENV.fetch("NOTES_BRANCH")}/docs/"
        body = body.gsub(/\]\((?!https:)([A-Za-z0-9_.-]+\.md)\)/) { "](#{base}#{$1})" }
        print body.rstrip
        print "\n\nInstall or update with Homebrew:\n\n```sh\n"
        print "brew install --cask riftvm/tap/riftvm\nbrew upgrade --cask riftvm\n```\n\n"
        print "Or download the app archive below.\n"
      ' "$notes_file"
    ;;

  check)
    missing=()
    while IFS= read -r tag; do
      [[ -n "$tag" ]] || continue
      is_exempt "$tag" && continue
      candidate="${tag#riftvm-v}"
      awk -v heading="## $candidate" 'index($0, heading) == 1 { found = 1; exit } END { exit found ? 0 : 1 }' "$notes_file" \
        || missing+=("$tag")
    done < <(git -C "$project_root" tag --list 'riftvm-v[0-9]*.[0-9]*.[0-9]*' --sort=version:refname)
    if [[ ${#missing[@]} -gt 0 ]]; then
      echo "release-notes: no section for: ${missing[*]}" >&2
      echo "Run '$0 prepare <version>' to add a draft." >&2
      exit 1
    fi
    echo "Release notes cover every release tag after the convention."
    ;;

  *)
    echo "usage: $0 prepare <major.minor.patch> | extract <major.minor.patch> | check" >&2
    exit 64
    ;;
esac
