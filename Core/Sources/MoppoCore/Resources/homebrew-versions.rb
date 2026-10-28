# frozen_string_literal: true

# Homebrew owns eligibility, locking, and removal. This adapter never removes files directly.
require "json"
require "digest"
require "formula"
require "cleanup"

module MoppoHomebrewVersions
  module_function

  def checked_path(path)
    path = Pathname.new(path).cleanpath
    raise "The Homebrew path changed. Scan again before removal." unless path.absolute?

    current = path
    loop do
      raise "A Homebrew path is not a regular directory." unless current.lstat.directory? && !current.symlink?
      break if current.root?

      current = current.parent
    end
    path
  end

  def identity(path)
    stat = path.lstat
    [stat.dev, stat.ino, stat.size, stat.mtime.to_i, stat.mtime.nsec]
  end

  def review(formula, keg)
    cellar = checked_path(HOMEBREW_CELLAR)
    path = checked_path(keg.to_s)
    raise "The formula version is outside the Homebrew Cellar." unless path.parent.parent == cellar
    raise "The formula name does not match its path." unless path.parent.basename.to_s == formula.name

    receipt = path/"INSTALL_RECEIPT.json"
    raise "Moppo cannot verify the installation receipt." unless receipt.lstat.file? && !receipt.symlink?
    raise "The installation receipt is too large." if receipt.size > 4 * 1024 * 1024

    token = Digest::SHA256.hexdigest(JSON.generate([
      HOMEBREW_VERSION, path.to_s, identity(path), identity(receipt), Digest::SHA256.file(receipt).hexdigest,
    ]))
    { name: formula.name, version: path.basename.to_s, path: path.to_s, token: token }
  end

  def eligible(formula)
    # Pinned formulae stay protected, including their older versions.
    return [] if formula.pinned?

    formula.eligible_kegs_for_cleanup(quiet: true).reject { |keg| keg.linked? || keg.optlinked? }
  end

  def inventory
    versions = []
    unreadable = 0
    Formula.racks.each do |rack|
      begin
        formula = Formulary.from_rack(rack)
        versions.concat(eligible(formula).map { |keg| review(formula, keg) })
      rescue StandardError => error
        unreadable += 1
        warn "#{rack.basename}: #{error.message[0, 512]}"
      end
    end
    puts JSON.generate({ versions: versions, unreadableCount: unreadable })
  end

  def remove(path, token)
    path = checked_path(path)
    raise "The formula version is outside the Homebrew Cellar." unless path.parent.parent == checked_path(HOMEBREW_CELLAR)

    keg = Keg.new(path)
    keg.lock do
      Formula.clear_cache
      formula = Formulary.from_rack(path.parent)
      candidate = eligible(formula).find { |item| Pathname.new(item) == path }
      raise "This formula version is active, protected, or no longer obsolete. Scan again." unless candidate
      raise "The formula version changed. Scan again before removal." unless review(formula, candidate)[:token] == token

      cleanup = Homebrew::Cleanup.new
      cleanup.cleanup_keg(candidate)
      raise "Homebrew could not remove this formula version." unless cleanup.unremovable_kegs.empty? && !path.exist?
    end
  end

  def run(arguments)
    case arguments
    in ["inventory"] then inventory
    in ["remove", String => path, String => token] then remove(path, token)
    else raise "The Homebrew command arguments are invalid."
    end
  rescue StandardError => error
    warn error.message
    exit 1
  end
end

MoppoHomebrewVersions.run(ARGV) if $PROGRAM_NAME == __FILE__
