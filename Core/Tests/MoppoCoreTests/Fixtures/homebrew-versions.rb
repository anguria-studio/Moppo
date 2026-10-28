require "tmpdir"
require "fileutils"
require "formula"
require "formulary"
require "tab"
require "cleanup"
require "stringio"
load ARGV.fetch(0)

def refuses(message)
  begin
    yield
  rescue StandardError => error
    raise "Wrong refusal: #{error.message}" unless error.message.include?(message)
    return
  end
  raise "Removal was not refused."
end

Dir.mktmpdir("moppo-homebrew-native-") do |temporary|
  root = Pathname(temporary).realpath
  { HOMEBREW_PREFIX: root, HOMEBREW_CELLAR: root/"Cellar", HOMEBREW_LINKED_KEGS: root/"var/homebrew/linked",
    HOMEBREW_PINNED_KEGS: root/"var/homebrew/pinned", HOMEBREW_LOCKS: root/"var/homebrew/locks",
    HOMEBREW_CACHE: root/"cache", HOMEBREW_LOGS: root/"logs" }.each do |name, value|
    Object.send(:remove_const, name)
    Object.const_set(name, value)
    value.mkpath
  end
  source = <<~SOURCE
    class MoppoFixture < Formula
      url "https://example.invalid/moppo-fixture-3.0.tar.gz"
      version "3.0"
      sha256 "#{'a' * 64}"
    end
  SOURCE
  formula = Formulary.from_contents("moppo-fixture", root/"moppo-fixture.rb", source)
  Formulary.define_singleton_method(:from_rack) { |*| formula }
  %w[1.0 2.0 3.0].each do |version|
    path = formula.rack/version
    (path/"bin").mkpath
    (path/"bin/tool").write("test data\n" * 10000)
    (path/"INSTALL_RECEIPT.json").write(JSON.generate({"homebrew_version"=>HOMEBREW_VERSION,"used_options"=>[],"unused_options"=>[],"built_as_bottle"=>false,"poured_from_bottle"=>false,"time"=>1,"source"=>{"path"=>(root/"moppo-fixture.rb").to_s,"tap"=>nil,"spec"=>"stable","versions"=>{"stable"=>"3.0","head"=>nil,"version_scheme"=>0}}}))
  end
  (root/"opt").mkpath
  (root/"opt/moppo-fixture").make_symlink(formula.rack/"3.0")
  old = formula.rack/"1.0"
  other = formula.rack/"2.0"
  current = formula.rack/"3.0"
  opt = root/"opt/moppo-fixture"
  linked = HOMEBREW_LINKED_KEGS/"moppo-fixture"
  (root/"cache/bottle").write("cached download")
  (root/"settings").write("user settings")
  raise "Wrong eligibility" unless MoppoHomebrewVersions.eligible(formula).map(&:to_s).sort == [old.to_s, other.to_s]
  review = MoppoHomebrewVersions.review(formula, Keg.new(old))

  formula.pin
  raise "Pinned formula offered" unless MoppoHomebrewVersions.eligible(formula).empty?
  refuses("protected") { MoppoHomebrewVersions.remove(review[:path], review[:token]) }
  formula.unpin

  linked.make_symlink(old)
  refuses("protected") { MoppoHomebrewVersions.remove(review[:path], review[:token]) }
  linked.unlink
  opt.unlink
  opt.make_symlink(old)
  refuses("protected") { MoppoHomebrewVersions.remove(review[:path], review[:token]) }
  opt.unlink
  opt.make_symlink(current)

  keepme = old/Keg::KEEPME_FILE
  keepme.write((root/"settings").to_s)
  refuses("protected") { MoppoHomebrewVersions.remove(review[:path], review[:token]) }
  keepme.unlink

  receipt = old/"INSTALL_RECEIPT.json"
  receipt.write(receipt.read + "\n")
  refuses("changed") { MoppoHomebrewVersions.remove(review[:path], review[:token]) }
  review = MoppoHomebrewVersions.review(formula, Keg.new(old))

  saved = root/"original"
  old.rename(saved)
  FileUtils.cp_r(saved, old)
  refuses("changed") { MoppoHomebrewVersions.remove(review[:path], review[:token]) }
  FileUtils.rm_r(old)
  old.make_symlink(saved)
  refuses("regular directory") { MoppoHomebrewVersions.remove(review[:path], review[:token]) }
  old.unlink
  saved.rename(old)
  review = MoppoHomebrewVersions.review(formula, Keg.new(old))
  refuses("outside") { MoppoHomebrewVersions.remove(root.to_s, review[:token]) }

  output = StringIO.new
  previous = $stdout
  $stdout = output
  begin
    MoppoHomebrewVersions.inventory
  ensure
    $stdout = previous
  end
  inventory = JSON.parse(output.string)
  raise "Inventory incomplete" unless inventory["unreadableCount"].zero? && inventory["versions"].length == 2

  # An unverifiable version withholds every version from the same formula.
  other_receipt = other/"INSTALL_RECEIPT.json"
  saved_receipt = root/"saved-receipt"
  other_receipt.rename(saved_receipt)
  other_receipt.make_symlink(saved_receipt)
  output = StringIO.new
  errors = StringIO.new
  previous_error = $stderr
  $stdout = output
  $stderr = errors
  begin
    MoppoHomebrewVersions.inventory
  ensure
    $stdout = previous
    $stderr = previous_error
  end
  inventory = JSON.parse(output.string)
  raise "Partial formula inventory offered" unless inventory["versions"].empty? && inventory["unreadableCount"] == 1
  other_receipt.unlink
  saved_receipt.rename(other_receipt)

  # A Homebrew failure must keep the selected version.
  original_cleanup = Homebrew::Cleanup.instance_method(:cleanup_keg)
  Homebrew::Cleanup.define_method(:cleanup_keg) { |_| raise "fixture command failure" }
  refuses("fixture command failure") { MoppoHomebrewVersions.remove(review[:path], review[:token]) }
  Homebrew::Cleanup.define_method(:cleanup_keg, original_cleanup)
  raise "Failed version removed" unless old.directory?

  MoppoHomebrewVersions.remove(review[:path],review[:token])
  raise "Selected version remains" if old.exist?
  raise "Other version removed" unless other.exist? && current.exist? && opt.realpath == current
  raise "Cache changed" unless (root/"cache/bottle").read == "cached download"
  raise "Settings changed" unless (root/"settings").read == "user settings"
  puts "Native Homebrew checks passed."
end
