# Developer tool storage catalog

[Back to the development notes](README.md#developer-tool-storage).

This catalog lists storage that developer tools create on a Mac.
It records which storage can come back after removal and which storage Moppo must never offer.
Use it to plan new scanner rules and protection rules.

> **Warning:** Add a removal rule only from a row with a `Verified` status.
> A `Found` or `Not verified` row does not give enough evidence for a rule.

AI tools are in the [AI storage sources and limits](ai-storage.md).
That document has priority for AI tool paths.

## Test environment

A person verified the rows on a disposable MacRent Mac mini on 2 and 3 November 2026.
The Mac had macOS 27.2 (26B123), Homebrew 7.0.12, an Apple M4 chip, and 32 GB of memory.
The `Moppo today` values come from the signed Moppo 0.6.0 and from an earlier Moppo build of `0a0cb82`.
Issue #257 keeps the test comments and the location of the evidence packet.

## Storage types

| Type | Meaning | Default treatment |
| --- | --- | --- |
| Cache | The tool rebuilds it without a network connection. | Moppo can offer it after verification. |
| Download | The tool downloads it again from a registry. | Moppo can offer it after verification. A network connection is necessary to restore it. |
| Build | The tool rebuilds it from project source files. | Moppo can offer it when a lockfile or manifest identifies the tool. |
| Installed | A version or package that the user installed. | Needs review. Use the tool command when one exists. Keep the active version. |
| Logs | Diagnostic records. | Needs review. The user can need them to find a problem. |
| User data | Databases, settings, projects, credentials, or other work. | Never offer. Show the size only. |

When a path can contain more than one type, use the most protective type.

## Columns

| Column | Contents |
| --- | --- |
| Path | The default macOS path. `~` is the home folder. `<project>` is a project folder. |
| Type | One type from the table above. |
| Recognition | The evidence that identifies the tool. A folder name alone is not evidence. |
| Removal | `Trash` for a normal Trash move. Otherwise, the tool command. |
| Moppo today | `Row` for a dedicated row. `Caches` for the general cache scan of `~/Library/Caches`, `~/Library/Logs`, and `~/.cache`. `Hidden` for the general Hidden System Data row of a large home folder. Moppo can move that folder to the Trash after review. `Protected` for a row that shows the size and refuses removal. Hidden & System Data or an application shows the row. A path in such a row is also `Protected`. `Size` for the storage breakdown only. `No` for no coverage. A ticket number for planned work. |
| Status | `Verified` with the date, the tool version, and the macOS version. `Found` when the tests found the path but did not remove it. `Not verified` with the reason. |

Homebrew paths use `/opt/homebrew` on Apple silicon and `/usr/local` on Intel Macs.

## Verification steps

Do these steps on a disposable test Mac.
Do not do these steps on a Mac with real work.

1. Install the tool from its official source. Record the tool version and the macOS version.
2. Run a typical task, such as a build, a dependency install, or a database start.
3. Record each new path and its allocated size.
4. Compare the paths with this catalog. Add missing rows.
5. Remove one row at a time with the method in the Removal column.
6. Run the restore command. Record whether the tool works again and whether it needs a network connection.
7. Change the Status to the date, the tool version, and the macOS version.
8. If a step fails, change the type to a more protective type and record the reason.

## Go

<!-- rules:begin go -->
| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `~/go/pkg/mod` | Download | `cache/download` folder inside. Folders and files are read-only. | `go clean -modcache` | `go mod download`. A network connection is necessary. | Row | Verified 2026-11-02, Go 1.27.3, macOS 27.2 |
| `~/Library/Caches/go-build` | Cache | `README` and hashed folders | Trash | Next build, without a network connection | Row | Verified 2026-11-02, Go 1.27.3, macOS 27.2 |
| `~/go/bin` | Installed | Executable files | Never remove automatically | `go install` | No | Verified 2026-11-02, Go 1.27.3, macOS 27.2 |
| `<project>/vendor` | Download | `vendor/modules.txt`, `go.mod`, and `go.sum` | Trash, only if Git does not track it | `go mod vendor`. It works without a network connection when the module cache contains the modules. | Row | Verified 2026-11-02, Go 1.27.3, macOS 27.2 |
| `~/Library/Caches/gopls` | Cache | Folder name and owner | Trash | Next `gopls` run | Caches | Verified 2026-11-02, gopls 0.24.0, macOS 27.2 |
| `~/Library/Caches/golangci-lint` | Cache | Folder name and owner | `golangci-lint cache clean` | Next lint run | Caches | Verified 2026-11-02, golangci-lint 2.15.0, macOS 27.2 |
| `~/.goenv` | Installed | `versions` and `shims` | Never offer. Use `goenv uninstall` for a version. | `goenv install` | Protected | Not verified. #342 checked the protection of these folders on the test Mac. No test removed the folder. |
| `~/.goenv/versions/<version>` | Installed | `goenv list` | `goenv uninstall <version> --yes` | `goenv install <version> --yes` | Protected | Verified 2026-11-02, goenv 3.2.2, macOS 27.2 |
| `~/.goenv/shared/go-mod` | Download | `cache/download` folder inside | Trash | `goenv install <version> --yes`. A network connection is necessary. | Row | Verified 2026-11-03, goenv 3.2.2, macOS 27.2 |
| `~/.goenv/releases-cache.json` | Cache | goenv layout | Trash | Next `goenv install` | Row | Verified 2026-11-03, goenv 3.2.2, macOS 27.2 |
<!-- rules:end go -->

goenv 3 installs default tools, such as `gopls` and `staticcheck`, into each version.
It keeps their modules in `~/.goenv/shared/go-mod`, 1.1 GiB in the test.
That folder stays after `goenv uninstall`.
The installed tools ran after the removal of `~/.goenv/shared/go-mod`.
`goenv install --list` and `goenv refresh` did not write `releases-cache.json` again. The next `goenv install` wrote it.
Moppo shows `~/.goenv` as a protected Hidden System Data row. Moppo offers only `shared/go-mod` and `releases-cache.json` in it.
`goenv uninstall` without `--yes` asks for confirmation and skips the removal when no terminal answers.

## Rust

<!-- rules:begin rust -->
| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `~/.cargo/registry` | Download | `CACHEDIR.TAG`, and `index`, `cache`, and `src` folders | Trash | Next build. A network connection is necessary. | Row | Verified 2026-11-02, Cargo 1.99.1, macOS 27.2 |
| `~/.cargo/git` | Download | `CACHEDIR.TAG`, and `db` and `checkouts` folders | Trash | Next build. A network connection is necessary. | Row | Verified 2026-11-02, Cargo 1.99.1, macOS 27.2 |
| `~/.cargo/bin` | Installed | Executable files. It also contains the `rustup` proxies. | Never remove automatically | `cargo install` | No | Verified 2026-11-02, Cargo 1.99.1, macOS 27.2 |
| `<project>/target` | Build | `Cargo.lock` beside the folder. `CACHEDIR.TAG` inside. | Trash | `cargo build`. It works without a network connection when the registry contains the crates. | Row | Verified 2026-11-02, Cargo 1.99.1, macOS 27.2 |
| `~/.rustup` | Installed | `settings.toml` and `toolchains` | Never offer. Use `rustup toolchain uninstall` for a toolchain. | `rustup toolchain install` | Protected | Not verified. #342 checked the protection of these folders on the test Mac. No test removed the folder. |
| `~/.rustup/toolchains/<name>` | Installed | `rustup toolchain list` | `rustup toolchain uninstall <name>` | `rustup toolchain install <name>` | Protected | Verified 2026-11-02, rustup 1.29.2, macOS 27.2 |
| `~/.rustup/downloads`, `~/.rustup/tmp` | Cache | Folder location | Trash | Not necessary | Row | Verified 2026-11-02, rustup 1.29.2, macOS 27.2 |
| `~/Library/Caches/Mozilla.sccache` | Cache | Folder name | Trash | Next build | Caches | Verified 2026-11-02, sccache 0.19.0, macOS 27.2 |
<!-- rules:end rust -->

Keep the default toolchain and each toolchain that a `rust-toolchain.toml` file names.

> **Warning:** Moppo can move all of `~/.rustup` to the Trash after review.
> After that move, `cargo` and `rustc` stop working.
> `rustup default stable` downloads the default toolchain again. Other toolchains do not come back.

## PHP

<!-- rules:begin php -->
| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `~/.composer`, `~/.config/composer` | User data | Folder name | Never offer. `auth.json` can contain registry tokens. | Not possible | Protected | Not verified. #342 checked the protection of these folders on the test Mac. No test removed the folder. |
| `~/Library/Caches/composer` | Download | Folder name | Trash | `composer install`. A network connection is necessary. | Row | Verified 2026-11-02, Composer 2.11.1, macOS 27.2 |
| `~/.composer/cache`, `~/.cache/composer` | Download | Folder location | Trash | `composer install` | No | Not created by Composer 2.11.1 on macOS 27.2 |
| `~/.composer/vendor`, `~/.config/composer/vendor` | Installed | `composer global show` | `composer global remove <package>` | `composer global require <package>` | Protected | Verified 2026-11-02 for `~/.composer/vendor`, Composer 2.11.1, macOS 27.2 |
| `<project>/vendor` | Download | `vendor/composer/installed.json` and `composer.lock` | Trash, only if Git does not track it | `composer install`. It works without a network connection when the Composer cache contains the packages. | Row | Verified 2026-11-02, Composer 2.11.1, macOS 27.2 |
| `<project>/storage/framework/cache`, `<project>/storage/framework/views` | Cache | `artisan` file in the project | `php artisan optimize:clear` | Next request | No | Verified 2026-11-02, PHP 8.5.12, macOS 27.2 |
| `<project>/bootstrap/cache` | Cache | `artisan` file in the project | `php artisan optimize:clear` | Next request | No | Verified 2026-11-02, PHP 8.5.12, macOS 27.2 |
| `<project>/storage/logs/*.log` | Logs | `artisan` file in the project | Trash the log files after review. Keep the folder. | Not possible | No | Verified 2026-11-03, Laravel 13.39.0, PHP 8.5.12, macOS 27.2 |
| `<project>/var/cache` | Cache | `bin/console` and `symfony.lock` | `php bin/console cache:clear` | The command builds the cache again. | No | Verified 2026-11-02, PHP 8.5.12, macOS 27.2 |
| `~/Library/Application Support/Herd` | User data | Herd installed | Never offer | Not possible | No | Not verified. The Herd app needs the desktop session. |
| `~/.config/valet` | User data | Valet installed | Never offer | Not possible | No | Not verified. `valet install` changes the DNS resolver and the `sudoers` file. |
<!-- rules:end php -->

Herd and Valet can contain site settings, certificates, and database services.
Composer 2.11.1 keeps its home in `~/.composer` and its cache in `~/Library/Caches/composer` on macOS.
`~/.composer` can contain `auth.json` with registry tokens. Moppo shows it as a protected Hidden System Data row.
Moppo shows Laravel and Symfony project folders as general Documents and Files rows. It does not select them.
Laravel wrote a new log file and a new `storage/logs` folder at the next log entry.
After a Trash move of the complete folder, `storage/logs/.gitignore` did not come back.
Moppo 0.6.0 includes the verified `vendor` rows from #256. The scanner hides project folders smaller than 1 MiB.

## Perl

<!-- rules:begin perl -->
| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `~/.cpanm` | Cache | `latest-build` link | Never offer whole. Moppo offers `work` as a row. | Next install | Protected | Not verified. #342 checked the protection of these folders on the test Mac. No test removed the folder. |
| `~/.cpanm/work` | Cache | `latest-build` link in `~/.cpanm` | Trash | Next install | Row | Verified 2026-11-02, cpanm from Homebrew, macOS 27.2 |
| `~/.cpanm/build.log` | Cache | Folder location | Trash | Next install | Protected | Verified 2026-11-02, cpanm from Homebrew, macOS 27.2 |
| `~/perl5/lib/perl5` | Installed | `local::lib` layout | Never remove automatically | `cpanm --local-lib=~/perl5 <module>`. A network connection is necessary. | No | Verified 2026-11-03, cpanm from Homebrew, macOS 27.2 |
| `~/perl5/perlbrew/perls/<version>` | Installed | `perlbrew list` | `perlbrew uninstall <version>` | `perlbrew install <version>` | No | Verified 2026-11-02, perl-5.44.0 through perlbrew, macOS 27.2 |
| `~/perl5/perlbrew/build`, `~/perl5/perlbrew/dists` | Cache | perlbrew layout | `perlbrew clean` | Next install | No | Verified 2026-11-02, perlbrew, macOS 27.2 |
| `~/.plenv` | Installed | `versions` | Never offer. Use `plenv uninstall` for a version. | `plenv install` | Protected | Not verified. #342 checked the protection of these folders on the test Mac. No test removed the folder. |
| `~/.plenv/versions/<version>` | Installed | `plenv versions` | `plenv uninstall -f <version>` | `plenv install <version>` | Protected | Verified 2026-11-03, plenv 2.3.1 with perl-build 1.34 and Perl 5.44.0, macOS 27.2 |
| `~/.plenv/build` | Cache | plenv layout | Trash | Not necessary | Row | Verified 2026-11-03, plenv 2.3.1, macOS 27.2 |
| `~/.plenv/cache` | Download | Perl source archives in the plenv layout | Trash | Next `plenv install`. A network connection is necessary. | Row | Verified 2026-11-03, plenv 2.3.1, macOS 27.2 |
| `<project>/local` | Download | `cpanfile.snapshot` beside the folder | Trash, only if Git does not track it | `carton install` | No | Verified 2026-11-02, Carton, macOS 27.2 |
<!-- rules:end perl -->

After one Perl build, `~/perl5/perlbrew/build` used 229 MiB. `perlbrew clean` removed it.
After one Perl build, `~/.plenv/build` used 229 MiB and `~/.plenv/cache` used 20 MiB. Perl ran after their removal.
`carton` stopped after the removal of `~/perl5/lib/perl5`. `cpanm` restored the modules.
The Perl in macOS has its own copy of some modules, such as `Try::Tiny`. Test a removal with a module that only `~/perl5` contains.
Moppo does not show `~/perl5`. The general hidden folder row includes only hidden folders.
Moppo offers `~/.cpanm/work` as a row. The `build.log` file stays in the protected `~/.cpanm` row.

## Python

Moppo has rows for the pip, uv, Poetry, and Pipenv caches.
Project `.venv` folders, `__pycache__`, and tagged analysis caches also have rows.
In the 2026-11-02 test, Moppo offered `~/Library/Caches/pip`, `~/Library/Caches/pypoetry/cache`, and `~/Library/Caches/pypoetry/artifacts`.

<!-- rules:begin python -->
| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `~/.pyenv` | Installed | Folder name | Never offer. Use `pyenv uninstall` for a version. | `pyenv install` | Protected | Not verified. #342 checked the protection of these folders on the test Mac. No test removed the folder. |
| `~/.pyenv/versions/<version>` | Installed | `pyenv versions` | `pyenv uninstall -f <version>` | `pyenv install <version>` | Protected | Verified 2026-11-02, pyenv 2.8.14, macOS 27.2 |
| `~/miniconda3/pkgs`, `~/anaconda3/pkgs`, `~/miniforge3/pkgs` | Download | `conda info` | `conda clean --all` | Next install | No | Verified 2026-11-02 for `~/miniforge3`, conda 26.9.4, macOS 27.2 |
| `~/miniconda3/envs/<name>`, `~/anaconda3/envs/<name>`, `~/miniforge3/envs/<name>` | Installed | `conda env list` | `conda env remove --name <name>` after review | `conda env create` from an environment file | No | Verified 2026-11-02 for `~/miniforge3`, conda 26.9.4, macOS 27.2 |
| `~/Library/Caches/pypoetry/virtualenvs` | Installed | Poetry layout | Trash after review | `poetry install` with `poetry.lock` | No | Verified 2026-11-02, Poetry 2.5.1, macOS 27.2 |
| `~/Library/Caches/pypoetry/cache` | Download | Poetry layout | Trash | Next `poetry install`. A network connection is necessary. | Row | Found 2026-11-02. Not verified. Moppo offered the row in the test. No test removed the folder. |
| `~/Library/Caches/pypoetry/artifacts` | Download | Poetry layout | Trash | Next `poetry install`. A network connection is necessary. | Row | Found 2026-11-02. Not verified. Moppo offered the row in the test. No test removed the folder. |
| `~/Library/Application Support/pipx/venvs` | Installed | `pipx list` | `pipx uninstall <package>` | `pipx install <package>` | No | Verified 2026-11-02, pipx 1.18.11, macOS 27.2 |
| `~/Library/Logs/pipx` | Logs | Folder location | Trash after review | Not possible | Caches | Verified 2026-11-03, pipx 1.18.11, macOS 27.2 |
| `~/.cache/pre-commit` | Cache | Folder location | `pre-commit clean` | Next hook run. A network connection is necessary. | Caches | Verified 2026-11-02, pre-commit 4.7.0, macOS 27.2 |
| `~/Library/Caches/pip` | Download | Folder name | Trash | Next `pip install`. A network connection is necessary. | Row | Found 2026-11-02. Not verified. Moppo offered the row in the test. No test removed the folder. |
| `~/.cache/uv` | Download | Folder name | Trash | Next `uv sync`. A network connection is necessary. | Row | Not verified. The rule is older than the catalog. No test Mac removed the folder. |
| `~/Library/Caches/pipenv` | Download | Folder name | Trash | Next `pipenv install`. A network connection is necessary. | Row | Not verified. The rule is older than the catalog. No test Mac removed the folder. |

Poetry keeps its downloads in `cache` and `artifacts`. The `virtualenvs` folder beside them holds project environments, which no rule offers.
uv links or clones environments out of this cache, so they survive its removal. `uv cache clean` is the tool's own instruction.
<!-- rules:end python -->

pipx 1.18 uses `~/Library/Application Support/pipx` on macOS. The path `~/.local/pipx` is from older pipx versions.
pipx creates `~/Library/Logs/pipx` again at the next command. The old logs do not come back.
Moppo 0.6.0 offered `~/Library/Logs/pipx` as safe, because it treated `~/Library/Logs` as a cache folder.
Since #336, Moppo shows each item in `~/Library/Logs` as **Not regenerable**. **Safe to Remove** does not select these items.
`conda clean --all` did not damage existing environments.
pyenv can build Python 3.12 only with OpenSSL 3. When Homebrew has OpenSSL 4, set `PYTHON_BUILD_HOMEBREW_OPENSSL_FORMULA=openssl@3`.

## Ruby

Moppo has a row for the Bundler cache in `~/.bundle/cache`.

<!-- rules:begin ruby -->
| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `~/.local/share/gem` | Installed | `gem list` | `gem uninstall --user-install <gem>` | `gem install --user-install <gem>` | Protected | Verified 2026-11-02, RubyGems 3.5.22, macOS 27.2 |
| `~/.gem` | Installed | `gem list` | `gem uninstall <gem>` | `gem install <gem>` | No | Not created by RubyGems 3.5.22 |
| `~/.rbenv` | Installed | Folder name | Never offer. Use `rbenv uninstall` for a version. | `rbenv install` | Protected | Not verified. #342 checked the protection of these folders on the test Mac. No test removed the folder. |
| `~/.rbenv/versions/<version>` | Installed | `rbenv versions` | `rbenv uninstall -f <version>` | `rbenv install <version>` | Protected | Verified 2026-11-02, Ruby 3.3.13 through rbenv, macOS 27.2 |
| `~/.rvm` | Installed | Folder name | Never offer. Use `rvm remove` or `rvm cleanup all`. | `rvm install` | Protected | Not verified. #342 checked the protection of these folders on the test Mac. No test removed the folder. |
| `~/.rvm/rubies/<version>` | Installed | `rvm list` | `rvm remove <version>` | `rvm install <version>` | Protected | Verified 2026-11-03, RVM 1.29.12-next with Ruby 3.3.13, macOS 27.2 |
| `~/.rvm/archives`, `~/.rvm/src` | Cache | RVM layout | `rvm cleanup all` | Next install. A network connection is necessary. | Protected | Verified 2026-11-03, RVM 1.29.12-next, macOS 27.2 |
| `~/.rubies` | Installed | Folder name | Never offer. Projects can need these versions. | `ruby-install` | Protected | Not verified. #342 checked the protection of these folders on the test Mac. No test removed the folder. |
| `~/.rubies/<version>` | Installed | chruby lists the folder | Trash after review | `ruby-install ruby <version>` | Protected | Verified 2026-11-03, chruby 0.3.9 and ruby-install 0.10.2, macOS 27.2 |
| `~/src/ruby-<version>`, `~/src/ruby-<version>.tar.xz` | Cache | ruby-install layout and a matching folder in `~/.rubies` | Trash | Not necessary | No | Verified 2026-11-03, ruby-install 0.10.2, macOS 27.2 |
| `~/.cache/ruby-install` | Cache | Folder location | Trash | Next `ruby-install` run | Caches | Verified 2026-11-03, ruby-install 0.10.2, macOS 27.2 |
| `~/.gnupg` | User data | GnuPG layout | Never offer | Not possible | Protected | Found 2026-11-03, GnuPG 2.5.24, macOS 27.2 |
| `<project>/vendor/bundle` | Download | `Gemfile.lock` beside `vendor`, and `BUNDLE_PATH` in `.bundle/config` | Trash, only if Git does not track it | `bundle install`. A network connection is necessary. | Row | Verified 2026-11-02, Bundler 2.5.22, macOS 27.2 |
| `~/.bundle/cache` | Download | Folder name | Trash | Next `bundle install`. A network connection is necessary. | Row | Not verified. The rule is older than the catalog. No test Mac removed the folder. |
<!-- rules:end ruby -->

RubyGems 3.5 writes `--user-install` gems to `~/.local/share/gem`, not to `~/.gem`.
Moppo offers the `vendor` folder only when it contains only `bundle`. A `vendor/cache` folder from `bundle cache` keeps it protected.
`bundle install --local` did not restore `vendor/bundle` in this test.
RVM stable 1.29.12 does not know Ruby 3.3 and asks for the removed `openssl@1.1` formula. Use `rvm get master`.
After one install, `~/.rvm/src` used 266 MiB. `rvm remove` also removed the gem folders of that Ruby.
ruby-install keeps the source folder and the archive in `~/src`, 330 MiB for Ruby 3.3.13. Ruby ran after their removal.
The RVM install imported the RVM signing keys into `~/.gnupg`. That folder can contain private keys.
Moppo does not show `~/src`. The general hidden folder row includes only hidden folders.

## Java, Kotlin, and Scala

Moppo has rows for the Gradle caches, Gradle distributions, Ivy, and Coursier.
In the 2026-11-02 test, Moppo offered `~/.gradle/caches` and `~/Library/Caches/Coursier`.

<!-- rules:begin java -->
| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `~/.m2` | User data | Folder name | Never offer whole. Moppo offers `repository` for review. | Not possible for `settings.xml` | Protected | Not verified. #342 checked the protection of these folders on the test Mac. No test removed the folder. |
| `~/.m2/repository` | Download | Maven layout | Trash | Next Maven build. A network connection is necessary. | Row | Verified 2026-11-02, Maven 3.10.0, macOS 27.2 |
| `<project>/target` | Build | `pom.xml` beside the folder | Trash | `mvn package`. It works without a network connection when the repository contains the dependencies. | Row | Verified 2026-11-02, Maven 3.10.0, macOS 27.2 |
| `~/.gradle/daemon` | Logs | Gradle layout | Trash when no Gradle daemon runs | Next build | No | Verified 2026-11-02, Gradle 9.8.2, macOS 27.2 |
| `~/.gradle/caches` | Download | Gradle layout | Trash | Next build. A network connection is necessary. | Row | Found 2026-11-02. Not verified. Moppo offered the row in the test. No test removed the folder. |
| `~/.gradle/wrapper/dists` | Download | Gradle layout | Trash | Next build with the wrapper. A network connection is necessary. | Row | Not verified. The rule is older than the catalog. No test Mac removed the folder. |
| `~/.sbt` | User data | `1.0` folder | Never offer whole. Moppo offers `boot` as a row. | Not possible for settings and plugins | Protected | Not verified. #342 checked the protection of these folders on the test Mac. No test removed the folder. |
| `~/.sbt/boot` | Download | sbt layout | Trash | Not necessary for sbt 2 | Row | Verified 2026-11-02, sbt 2.0.12, macOS 27.2 |
| `~/Library/Caches/Coursier` | Download | Folder name | Trash | Next sbt run. A network connection is necessary. | Row | Verified 2026-11-03, sbt 2.0.12, macOS 27.2 |
| `~/.sdkman` | Installed | Folder name | Never offer. Use `sdk uninstall` or `sdk flush`. | `sdk install` | Protected | Not verified. #342 checked the protection of these folders on the test Mac. No test removed the folder. |
| `~/.sdkman/candidates/<tool>/<version>` | Installed | `sdk list` | `sdk uninstall <tool> <version>` | `sdk install <tool> <version>` | Protected | Verified 2026-11-02, jbang 0.143.0 through SDKMAN, macOS 27.2 |
| `~/.sdkman/tmp` | Cache | SDKMAN layout | `sdk flush` | Next install | Protected | Verified 2026-11-02, macOS 27.2 |
| `~/.sdkman/archives` | Cache | SDKMAN layout | `sdk flush` | Next install | Protected | Not created in the 2026-11-02 test |
| `~/.konan` | Download | `dependencies` folder with the Kotlin/Native LLVM and `libffi` | Trash | Next `kotlinc-native` build. A network connection is necessary. | Hidden | Verified 2026-11-03, Kotlin/Native 2.4.21, macOS 27.2 |
| `~/Library/Caches/JetBrains/<product><version>` | Cache | Older version than the installed IDE | Trash | Next IDE start | Caches | Not verified. The IDE needs the desktop session. |
| `~/Library/Application Support/JetBrains/<product><version>` | User data | IDE settings | Never offer | Not possible | No | Not verified. The IDE needs the desktop session. |
| `~/.ivy2/cache` | Download | Ivy layout | Trash | Next sbt run. A network connection is necessary. | Row | Not verified. The rule is older than the catalog. No test Mac removed the folder. |

Maven 3.10 writes `.meta` in its repository. An older layout gets no offer.
The Gradle wrapper keeps a full distribution for each project-pinned version under `dists`.
`~/.ivy2/local` holds what the user published with `publishLocal`. Only `cache` is a download.
<!-- rules:end java -->

`~/.m2` can contain `settings.xml` with repository passwords. Moppo protects `~/.m2` and offers only `~/.m2/repository` for review.
sbt 2 compiled after the removal of `~/.sbt/boot` and did not create it again.
sbt 2 downloaded the 133 MiB Coursier cache again in 6 seconds.
SDKMAN needs Bash 4 or later. Install a newer Bash before you install SDKMAN on macOS.
The project scanner hides a `target` folder that is smaller than 1 MiB.
The test used the `kotlinc-native` compiler from the official release archive. It downloaded 688 MiB into `~/.konan/dependencies`.
The test did not use the Kotlin Gradle plugin.

## Android

<!-- rules:begin android -->
| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `~/Library/Android/sdk` | Installed | `.knownPackages`, `platform-tools`, `build-tools`, or `cmdline-tools` | Never offer. Use `sdkmanager --uninstall` for a package. | `sdkmanager <package>` | Protected | Not verified. #350 checked the protection on the test Mac. No test removed the folder. |
| `~/Library/Android/sdk/system-images` | Download | `sdkmanager --list_installed` | `sdkmanager --uninstall <package>` | `sdkmanager <package>` | Protected | Verified 2026-11-02, system image android-36 arm64, macOS 27.2 |
| `~/Library/Android/sdk/ndk/<version>` | Download | `sdkmanager --list_installed` | `sdkmanager --uninstall <package>` | `sdkmanager <package>` | Protected | Verified 2026-11-03, NDK 30.0.16248370, macOS 27.2 |
| `~/Library/Android/sdk/build-tools/<version>` | Download | `sdkmanager --list_installed` | `sdkmanager --uninstall <package>` | `sdkmanager <package>` | Protected | Verified 2026-11-02, build tools 37.0.0, macOS 27.2 |
| `~/Library/Android/sdk/emulator` | Download | `sdkmanager --list_installed` | `sdkmanager --uninstall emulator` | `sdkmanager emulator` | Protected | Verified 2026-11-03, emulator 37.2.13, macOS 27.2 |
| `~/.android` | User data | Folder name | Never offer whole. Use `avdmanager` for an emulator. Moppo offers `cache` as a row. | Not possible for adb keys | Protected | Not verified. #342 checked the protection of these folders on the test Mac. No test removed the folder. |
| `~/.android/avd` | User data | `avdmanager list avd` | `avdmanager delete avd --name <name>` after review | Create the emulator again | Protected | Verified 2026-11-02 for an AVD that never started, macOS 27.2 |
| `~/.android/cache` | Cache | Folder location | Trash | Not necessary | Row | Verified 2026-11-02, cmdline-tools from Homebrew, macOS 27.2 |
| `~/Library/Caches/Google/AndroidStudio<version>` | Cache | Older version than the installed IDE | Trash | Next IDE start | Caches | Not verified. Android Studio needs the desktop session. |
<!-- rules:end android -->

Emulator images contain installed apps and test data. Treat them as user data until verification.
The tested AVD never started, so it contained no apps or data.
Moppo shows `~/Library/Android/sdk` as one protected Hidden System Data row. The SDK used about 9 GB in this test. The NDK used 2.8 GiB of it.
Moppo does not offer SDK packages because only `sdkmanager` removes them correctly.
`~/.android/avd` stayed after the removal of the emulator package.
The Homebrew `avdmanager` does not find an SDK in `~/Library/Android/sdk`. Use `cmdline-tools;latest` from that SDK.
`sdkmanager` did not create `~/.android/cache` again after its removal.

## .NET

Moppo has a row for NuGet packages in `~/.nuget/packages`.

<!-- rules:begin dotnet -->
| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `~/.local/share/NuGet` | Cache | `http-cache` or `Migrations` folder | Never offer. Use `dotnet nuget locals http-cache --clear`. | Next restore | Protected | Not verified. #350 checked the protection on the test Mac. No test removed the folder. |
| `~/.nuget/packages` | Download | `dotnet nuget locals global-packages --list` | Trash | Next restore. A network connection is necessary. | Row | Verified 2026-11-02, .NET SDK 10.0.403, macOS 27.2 |
| `~/.local/share/NuGet/http-cache` | Cache | `dotnet nuget locals http-cache --list` | `dotnet nuget locals http-cache --clear` | Next restore | Protected | Verified 2026-11-02, .NET SDK 10.0.403, macOS 27.2 |
| `/usr/local/share/dotnet/sdk/<version>` | Installed | `dotnet --list-sdks` | Official uninstall tool after review | Install the SDK again | No | Found 2026-11-02, .NET SDK 10.0.403. Not verified. The uninstall tool needs administrator rights. |
| `<project>/bin`, `<project>/obj` | Build | `.csproj` or `.fsproj` beside the folders | Trash | `dotnet build` | #49 | Verified 2026-11-02, .NET SDK 10.0.403, macOS 27.2 |
<!-- rules:end dotnet -->

The Homebrew `dotnet-sdk` cask installs the SDK in `/usr/local/share/dotnet`, also on Apple silicon.
Moppo shows `~/.local/share/NuGet` as a protected Hidden System Data row at any size. It does not offer the HTTP cache, because the catalog verified only the `dotnet` command.

## Elixir, Erlang, and Haskell

Moppo has rows for Hex packages and Cabal packages.
In the 2026-11-02 test, Moppo offered `~/.hex/packages`.

<!-- rules:begin elixir-haskell -->
| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `~/.mix` | Installed | Folder name | Never offer. Use `mix archive.uninstall`. | `mix local.hex --force` | Protected | Not verified. #342 checked the protection of these folders on the test Mac. No test removed the folder. |
| `<project>/_build` | Build | `mix.exs` beside the folder | Trash | `mix compile` | #49 | Verified 2026-11-02, Elixir 1.20.5, macOS 27.2 |
| `<project>/deps` | Download | `mix.lock` beside the folder | Trash | `mix deps.get`. A network connection is necessary. | No | Verified 2026-11-02, Elixir 1.20.5, macOS 27.2 |
| `~/.mix/archives` | Installed | Mix layout | Never remove automatically | `mix local.hex --force` | Protected | Verified 2026-11-03, Hex 2.6.0 with Elixir 1.20.5, macOS 27.2 |
| `~/.ghcup` | Installed | Folder name | Never offer. Use `ghcup rm` or `ghcup gc`. | `ghcup install` | Protected | Not verified. #342 checked the protection of these folders on the test Mac. No test removed the folder. |
| `~/.ghcup/ghc/<version>` | Installed | `ghcup list` | `ghcup rm ghc <version>` | `ghcup install ghc <version>` | Protected | Verified 2026-11-02, GHC 9.10.3 through ghcup 0.2.6.2, macOS 27.2 |
| `~/.ghcup/cache` | Cache | ghcup layout | `ghcup gc --cache` | Next install | Protected | Verified 2026-11-02, ghcup 0.2.6.2, macOS 27.2 |
| `~/.local/state/cabal` | Installed | `store/ghc-<version>` folder | Never offer. Projects and programs from `cabal install` can need the store. | Next build | Protected | Not verified. #350 checked the protection on the test Mac. No test removed the folder. |
| `~/.cache/cabal` | Download | cabal layout | Trash after review | `cabal update` and the next build. A network connection is necessary. | Row | Verified 2026-11-03, cabal 3.16.1.0, macOS 27.2 |
| `~/.local/state/cabal/store` | Installed | cabal layout | Trash after review | Next build for project dependencies | Protected | Verified 2026-11-03, cabal 3.16.1.0, macOS 27.2 |
| `<project>/dist-newstyle` | Build | `.cabal` file beside the folder | Trash | `cabal build` | No | Verified 2026-11-02, cabal 3.16.1.0, macOS 27.2 |
| `~/.cabal/packages` | Download | cabal layout | Trash | `cabal update`. A network connection is necessary. | Row | Not verified. cabal 3.16 does not create this folder. Older cabal versions use it. See #323. |
| `~/.stack` | Installed | `config.yaml` and `stack.sqlite3` | Never offer whole. Moppo offers `snapshots`, `pantry`, and `setup-exe-cache` as rows. | Not possible for `config.yaml` | Protected | Not verified. #342 checked the protection of these folders on the test Mac. No test removed the folder. |
| `~/.stack/programs/<platform>/ghc-<version>` | Installed | Stack layout | Trash after review | Next `stack build`. A network connection is necessary. | Protected | Verified 2026-11-03, Stack 3.11.1 with GHC 9.10.3, macOS 27.2 |
| `~/.stack/snapshots` | Build | Stack layout | Trash | Next `stack build` | Row | Verified 2026-11-03, Stack 3.11.1, macOS 27.2 |
| `~/.stack/pantry`, `~/.stack/setup-exe-cache` | Download | Stack layout | Trash | Next `stack build`. A network connection is necessary. | Row | Verified 2026-11-03, Stack 3.11.1, macOS 27.2 |
| `~/.stack/config.yaml` | User data | Stack layout | Never offer | Not possible | Protected | Verified 2026-11-03, Stack 3.11.1, macOS 27.2 |
| `<project>/.stack-work` | Build | `stack.yaml` beside the folder | Trash | `stack build` | No | Verified 2026-11-03, Stack 3.11.1, macOS 27.2 |
| `~/.hex/packages` | Download | Hex layout | Trash | Next `mix deps.get`. A network connection is necessary. | Row | Found 2026-11-02. Not verified. Moppo offered the row in the test. No test removed the folder. |
<!-- rules:end elixir-haskell -->

cabal 3.16 uses the XDG layout on macOS. It did not create `~/.cabal`.
Moppo shows `~/.cache/cabal` as the `Cabal packages (XDG)` row in Package Manager Caches. The row needs review. It used 1.1 GiB in this test.
Moppo shows `~/.local/state/cabal` as a protected Hidden System Data row when a `store/ghc-<version>` folder identifies it.
Without `~/.cache/cabal`, `cabal build` stopped with `unknown package` until `cabal update` ran.
The next build restored the store for project dependencies. The test did not check programs from `cabal install`.
`mix compile` failed after the removal of `deps`. `mix deps.get` restored it.
With no terminal input, `mix deps.get` installed Hex again by itself.
Stack installed GHC in `~/.stack/programs`, 2.1 GiB in this test.
Stack wrote a new default `config.yaml` after a Trash move of `~/.stack`. The user setting in the old file did not come back.

> **Warning:** Moppo can move all of `~/.stack` to the Trash after review.
> That move removes the Stack settings in `config.yaml`.

## Version managers for more than one language

<!-- rules:begin version-managers -->
| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `~/.asdf` | Installed | `installs` and `plugins` | Never offer whole. Use `asdf uninstall` for a version. Moppo offers `downloads` as a row. | `asdf install` | Protected | Not verified. #342 checked the protection of these folders on the test Mac. No test removed the folder. |
| `~/.asdf/installs/<tool>/<version>` | Installed | `asdf list` | `asdf uninstall <tool> <version>` | `asdf install <tool> <version>` | Protected | Verified 2026-11-02, asdf 0.20.2, macOS 27.2 |
| `~/.asdf/downloads` | Cache | asdf layout | Trash | Next install | Row | Verified 2026-11-02, asdf 0.20.2, macOS 27.2 |
| `~/.local/share/mise` | Installed | `installs` folder | Never offer. Use `mise uninstall` for a version. | `mise install` | Protected | Not verified. #350 checked the protection on the test Mac. No test removed the folder. |
| `~/.local/share/mise/installs/<tool>/<version>` | Installed | `mise ls` | `mise uninstall <tool>@<version>` | `mise install <tool>@<version>` | Protected | Verified 2026-11-02, mise 2026.10.25, macOS 27.2 |
| `~/Library/Caches/mise` | Cache | Folder name | `mise cache clear` | Next install | Caches | Verified 2026-11-02, mise 2026.10.25, macOS 27.2 |
<!-- rules:end version-managers -->

Keep each version that a `.tool-versions` or `mise.toml` file in a project names.
Moppo shows `~/.asdf` as a protected Hidden System Data row when it is larger than 5 MiB. Moppo offers only `~/.asdf/downloads` in it.
Moppo shows `~/.local/share/mise` as a protected Hidden System Data row when it contains `installs`.

## Container and virtual machine tools

Moppo reviews Docker images and the Docker build cache through Docker.

<!-- rules:begin containers -->
| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `~/.colima` | User data | Colima installed | `colima delete` after review | Not possible for volumes after `colima delete --data` | Protected | Verified 2026-11-02, Colima 0.10.3, macOS 27.2 |
| `~/.colima/_lima/_disks/<profile>` | User data | Colima layout | `colima delete --data` after review | Not possible | Protected | Verified 2026-11-02, Colima 0.10.3, macOS 27.2 |
| `~/.lima` | User data | Folder name | Never offer. Use `limactl delete` after review. | Not possible | Protected | Not verified. #342 checked the protection of these folders on the test Mac. No test removed the folder. |
| `~/.lima/<instance>` | User data | `limactl list` | `limactl delete <instance>` after review | Not possible | Protected | Verified 2026-11-03, Lima 2.2.1, macOS 27.2 |
| `~/.lima/_config` | User data | Lima layout. It contains the `user` SSH key. | Never offer | Not possible | Protected | Verified 2026-11-03, Lima 2.2.1, macOS 27.2 |
| `~/Library/Caches/lima` | Download | `download/by-url-sha256` folder inside | Trash | Next `limactl start` of a new instance. A network connection is necessary. | Caches | Verified 2026-11-03, Lima 2.2.1, macOS 27.2 |
| `~/.orbstack` | User data | OrbStack installed | OrbStack settings after review | Not possible for volumes | No | Not verified. The OrbStack app needs a first start in the desktop session. |
| `~/.local/share/containers/podman/machine` | User data | Podman installed | `podman machine rm` after review | Not possible for volumes | Protected | Verified 2026-11-02, Podman 6.1.4, macOS 27.2 |
| `~/.local/share/containers/podman/machine/applehv/cache` | Download | Podman layout | Trash | `podman machine init`. A network connection is necessary. | Row | Verified 2026-11-03, Podman 6.1.4, macOS 27.2 |

Podman 6.1 keeps the machine disks and the machine SSH key here.
<!-- rules:end containers -->

Virtual machine disks can contain container volumes and databases. Moppo must not move them to the Trash.

> **Warning:** Moppo can move all of `~/.colima` or `~/.lima` to the Trash after review.
> These folders contain the virtual machines, their data disks, and the Lima SSH key.

`colima delete` keeps the container data disk in Colima 0.10.3. A volume came back after a new `colima start`.
`colima delete --data` also removes the data disk.
Colima 0.10.3 did not create `~/.lima`.
`limactl delete` removed the instance folder. A test file in the virtual machine did not come back.
In the test, the instance and the image cache each used 3.6 GiB.
`podman machine rm` left a 894 MiB machine image in the Podman cache folder.
The Podman machine used 7.8 GiB in the test. Moppo shows it as a protected Hidden System Data row.
The `machine` and `machine.pub` files are the SSH key of the machine.
Moppo offers `applehv/cache` only when `machine.pub` and a `.raw.zst` image identify the Podman layout.

## Credentials and cloud tools

These folders hold sign-in tokens, keys, and cluster settings. Moppo must never offer them.
The #321 rules protect them by name. Protection by name removes nothing, so the name is enough evidence for it.

<!-- rules:begin credentials -->
| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `~/.aws` | User data | `config` and `credentials` files | Never offer | Not possible | Protected | Not verified. The rule protects the folder by name. No test removed it. |
| `~/.azure` | User data | Azure CLI layout | Never offer | Not possible | Protected | Not verified. The rule protects the folder by name. No test removed it. |
| `~/.config/gcloud` | User data | Google Cloud CLI layout | Never offer | Not possible | Protected | Not verified. The rule protects the folder by name. No test removed it. |
| `~/.config/gh` | User data | `hosts.yml` with sign-in tokens | Never offer | Not possible | Protected | Not verified. The rule protects the folder by name. No test removed it. |
| `~/.docker` | User data | `config.json` with registry credentials | Never offer | Not possible | Protected | Not verified. The rule protects the folder by name. No test removed it. |
| `~/.kube` | User data | `config` file with cluster credentials | Never offer | Not possible | Protected | Not verified. The rule protects the folder by name. No test removed it. |
| `~/.ssh` | User data | Keys and `config` | Never offer | Not possible | Protected | Not verified. The rule protects the folder by name. No test removed it. |
<!-- rules:end credentials -->

`~/.gnupg` is in the Ruby section, because the RVM install created it.
Hidden & System Data lists the other folders in `~/.config` as separate rows.

## JavaScript

Moppo offers these caches by their path. The rules are older than the catalog. No test Mac verified a row.

<!-- rules:begin javascript -->
| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `~/.npm/_cacache` | Download | npm layout | Trash | Next `npm install`. A network connection is necessary. | Row | Not verified. The rule is older than the catalog. No test Mac removed the folder. |
| `~/Library/Caches/Yarn` | Download | Folder name | Trash | Next `yarn install`. A network connection is necessary. | Row | Not verified. The rule is older than the catalog. No test Mac removed the folder. |
| `~/.yarn/cache` | Download | Folder name | Trash | Next `yarn install`. A network connection is necessary. | Row | Not verified. The rule is older than the catalog. No test Mac removed the folder. |
| `~/.cache/yarn` | Download | Folder name | Trash | Next `yarn install`. A network connection is necessary. | Row | Not verified. The rule is older than the catalog. No test Mac removed the folder. |
| `~/.yarn/berry/cache` | Download | Yarn Berry layout | Trash | Next `yarn install`. A network connection is necessary. | Row | Not verified. The rule is older than the catalog. No test Mac removed the folder. |
| `~/Library/pnpm/store` | Download | pnpm layout | Trash | Next `pnpm install`. A network connection is necessary. | Row | Not verified. The rule is older than the catalog. No test Mac removed the folder. |
| `~/.pnpm-store` | Download | pnpm layout | Trash | Next `pnpm install`. A network connection is necessary. | Row | Not verified. The rule is older than the catalog. No test Mac removed the folder. |
| `~/Library/Caches/pnpm` | Cache | Folder name | Trash | Next `pnpm install` | Row | Not verified. The rule is older than the catalog. No test Mac removed the folder. |
| `~/.bun/install/cache` | Download | Bun layout | Trash | Next `bun install`. A network connection is necessary. | Row | Not verified. The rule is older than the catalog. No test Mac removed the folder. |
| `~/Library/Caches/deno` | Download | Folder name | Trash | Next `deno run`. A network connection is necessary. | Row | Not verified. The rule is older than the catalog. No test Mac removed the folder. |
| `~/Library/Caches/node-gyp` | Download | Folder name | Trash | Next native module build. A network connection is necessary. | Row | Not verified. The rule is older than the catalog. No test Mac removed the folder. |
| `~/Library/Caches/electron` | Download | Folder name | Trash | Next `npm install` of Electron. A network connection is necessary. | Row | Not verified. The rule is older than the catalog. No test Mac removed the folder. |
| `~/Library/Caches/electron-builder` | Download | Folder name | Trash | Next electron-builder run. A network connection is necessary. | Row | Not verified. The rule is older than the catalog. No test Mac removed the folder. |
| `~/Library/Caches/ms-playwright` | Download | Folder name | Trash | `npx playwright install`. A network connection is necessary. | Row | Not verified. The rule is older than the catalog. No test Mac removed the folder. |
| `~/.cache/ms-playwright` | Download | Folder name | Trash | `npx playwright install`. A network connection is necessary. | Row | Not verified. The rule is older than the catalog. No test Mac removed the folder. |
| `~/Library/Caches/Cypress` | Download | Folder name | Trash | `cypress install`. A network connection is necessary. | Row | Not verified. The rule is older than the catalog. No test Mac removed the folder. |

`~/.npm/_logs` stays. It is small, and npm asks users to attach it to bug reports.
Yarn 1 on macOS uses `~/Library/Caches/Yarn`. The `~/.yarn/cache` and `~/.cache/yarn` layouts come from Linux or a migrated home. A Mac can carry any of them.
The pnpm store is content-addressable. Its files are hard-linked or cloned into each project, so removal frees less than the row shows.
`~/.bun` also holds the Bun runtime. Only the install cache is a download.
Playwright's macOS default is `~/Library/Caches/ms-playwright`. `~/.cache/ms-playwright` is the Linux layout.
<!-- rules:end javascript -->

## Swift and Apple tools

Moppo offers these caches by their path. The rules are older than the catalog. No test Mac verified a row.

<!-- rules:begin swift -->
| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `~/Library/Caches/org.swift.swiftpm` | Download | Folder name | Trash | Next `swift build`. A network connection is necessary. | Row | Not verified. The rule is older than the catalog. No test Mac removed the folder. |
| `~/Library/Caches/org.carthage.CarthageKit` | Download | Folder name | Trash | Next `carthage update`. A network connection is necessary. | Row | Not verified. The rule is older than the catalog. No test Mac removed the folder. |
| `~/Library/Caches/CocoaPods` | Download | Folder name | Trash | Next `pod install`. A network connection is necessary. | Row | Not verified. The rule is older than the catalog. No test Mac removed the folder. |

`~/.cocoapods/repos` is not a row. It is a clone of the spec index, and a new clone is a multi-gigabyte download.
<!-- rules:end swift -->

## Dart

Moppo offers the two download folders of the pub cache by their path.

<!-- rules:begin dart -->
| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `~/.pub-cache/hosted` | Download | pub layout | Trash | Next `dart pub get`. A network connection is necessary. | Row | Not verified. The rule is older than the catalog. No test Mac removed the folder. |
| `~/.pub-cache/git` | Download | pub layout | Trash | Next `dart pub get`. A network connection is necessary. | Row | Not verified. The rule is older than the catalog. No test Mac removed the folder. |

`~/.pub-cache/bin` and `global_packages` hold what `pub global activate` installed. Only the two download folders are rows.
<!-- rules:end dart -->

## C and C++

Moppo offers the ccache folder by its path.

<!-- rules:begin c-cpp -->
| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `~/Library/Caches/ccache` | Cache | Folder name | Trash | Next build | Row | Not verified. The rule is older than the catalog. No test Mac removed the folder. |
<!-- rules:end c-cpp -->

## Homebrew

Moppo offers the Homebrew download cache by its path. Old formula versions are separate rows that Homebrew removes.

<!-- rules:begin homebrew -->
| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `~/Library/Caches/Homebrew` | Download | Folder name | Trash | Next `brew install`. A network connection is necessary. | Row | Not verified. The rule is older than the catalog. No test Mac removed the folder. |
<!-- rules:end homebrew -->

## Application data folders with other names

These applications keep data in folders that do not match their name or bundle identifier.
Moppo shows each folder with its application as user data, in App Uninstaller, and in Application Leftovers after an uninstall.

<!-- rules:begin application-data -->
| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `~/Library/Application Support/anythingllm-desktop` | User data | Folder name | App Uninstaller or Application Leftovers, after review | Not possible | Protected | Found 2026-11-03, AnythingLLM 1.19.0, macOS 27.2. The #216 tests found the folder after the first start of the signed application. No test removed it. |
| `~/Library/Application Support/CherryStudio` | User data | Folder name | App Uninstaller or Application Leftovers, after review | Not possible | Protected | Found 2026-11-03, Cherry Studio 2.1.10, macOS 27.2. The #216 tests found the folder after the first start of the signed application. No test removed it. |
| `~/.cherrystudio` | User data | Folder name | App Uninstaller or Application Leftovers, after review | Not possible | Protected | Found 2026-11-03, Cherry Studio 2.1.10, macOS 27.2. The #216 tests found the folder after the first start of the signed application. No test removed it. |
| `~/Library/Application Support/StabilityMatrix` | User data | Folder name | App Uninstaller or Application Leftovers, after review | Not possible | Protected | Found 2026-11-03, Stability Matrix 2.16.5, macOS 27.2. The #216 tests found the folder after the first start of the signed application. No test removed it. |
| `~/Library/Application Support/VoiceInk` | User data | Folder name | App Uninstaller or Application Leftovers, after review | Not possible | Protected | Found 2026-11-03, VoiceInk 2.21, macOS 27.2. The #216 tests found the folder after the first start of the signed application. No test removed it. |
| `~/Library/Application Support/t3code-v2` | User data | Folder name | App Uninstaller or Application Leftovers, after review | Not possible | Protected | Found 2026-11-03, T3 Code 0.1.6, macOS 27.2. The #216 tests found the folder after the first start of the signed application. No test removed it. |
| `~/Library/Application Support/superwhisper` | User data | Folder name | App Uninstaller or Application Leftovers, after review | Not possible | Protected | Found 2026-11-03, Superwhisper 3.1.0, macOS 27.2. The #216 tests found the folder after the first start of the signed application. No test removed it. |
| `~/superwhisper` | User data | `settings/settings.json` and `modes` | App Uninstaller or Application Leftovers, after review | Not possible | Protected | Found 2026-11-03, Superwhisper 3.1.0, macOS 27.2. The #216 tests found the folder after the first start of the signed application. No test removed it. |

AnythingLLM 1.19.0, team 35S2NMU3G4. The Electron package name is `anythingllm-desktop`.
Cherry Studio 2.1.10, team 87242QY66T. The Electron package name is `CherryStudio`. `~/.cherrystudio` holds the downloaded tools and the `config` folder of the application.
Stability Matrix 2.16.5, team 78LBV9V26G. The folder holds `global.json` and the logs.
VoiceInk 2.21, team V6J6A3VWY2. VoiceInk also uses its bundle identifier folder.
T3 Code 0.1.6, team ARK85ZXQ4Z. The application sets this folder. Its package name is `t3code`. `~/.t3` is not here: the T3 Code command-line server also uses it.
Superwhisper 3.1.0, team XDP69BYUP9. `~/superwhisper` holds settings, modes, and recordings.
<!-- rules:end application-data -->

## Databases

Database files are user data. Moppo must never offer them for removal.
If you remove a file while the server runs, you can damage the database.
Only the tool can remove its own logs and old data safely.

<!-- rules:begin databases -->
| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `/opt/homebrew/var/postgresql@<version>`, `/opt/homebrew/var/postgres` | User data | `PG_VERSION` file | Never offer | Not possible | Protected | Verified 2026-11-02 for `postgresql@18`, PostgreSQL 18.6, macOS 27.2 |
| `~/Library/Application Support/Postgres/var-<version>` | User data | Postgres.app installed and `PG_VERSION` file | Never offer | Not possible | Protected | Verified 2026-11-02, Postgres.app 2.9.6 with PostgreSQL 18, macOS 27.2 |
| `~/Library/Application Support/com.tinyapp.DBngin/Engines/<engine>/<id>` | User data | DBngin installed and a database file in the engine folder, such as `ibdata1` or `PG_VERSION` | Never offer | Not possible | Protected | Verified 2026-11-02, DBngin 27.0.2 with MySQL 9.7.2, macOS 27.2 |
| `/Users/Shared/DBngin` | Installed | DBngin installed. A `bin` folder in a version folder. | DBngin, after review | DBngin downloads the version again | Protected | Found 2026-11-02, DBngin 27.0.2. Not verified. Removal and restore need the DBngin app in the desktop session. |
| `/opt/homebrew/var/mysql` | User data | `ibdata1` or `mysql` folder | Never offer | Not possible | Protected | Verified 2026-11-02, MySQL 26.10, macOS 27.2 |
| `/opt/homebrew/var/mysql/binlog.<number>` | User data | `binlog.<number>` files and `binlog.index` | `PURGE BINARY LOGS` in MySQL after review | Not possible | Protected | Verified 2026-11-03, MySQL 26.10, macOS 27.2 |
| `/opt/homebrew/var/mongodb` | User data | `WiredTiger` files | Never offer | Not possible | Protected | Verified 2026-11-02, MongoDB 9.0.4, macOS 27.2 |
| `/opt/homebrew/var/db/redis` | User data | `dump.rdb` or `appendonly` files | Never offer | Not possible | Protected | Verified 2026-11-02, Redis 8.10.3, macOS 27.2 |
| `/opt/homebrew/var/lib/opensearch` | User data | `nodes/<number>/_state` folder | Never offer | Not possible | Protected | Verified 2026-11-02, OpenSearch 3.9.0, macOS 27.2 |
| `/opt/homebrew/var/lib/elasticsearch` | User data | `nodes/<number>/_state` or `_state` folder | Never offer | Not possible | Protected | Not verified. Homebrew core has no Elasticsearch formula. |
| `/opt/homebrew/var/log` | Logs | Service log files | Trash after review, when the service does not run | Not possible | No | Verified 2026-11-03, Redis 8.10.3, macOS 27.2 |
| `<project>/*.sqlite`, `<project>/*.sqlite3`, `<project>/*.db` | User data | `SQLite format 3` header | Never offer | Not possible | No | Verified 2026-11-03, SQLite 3.54.0, macOS 27.2 |
| `~/Library/DBeaverData` | User data | `workspace6/<project>/.dbeaver/data-sources.json` | Never offer | Not possible | Protected | Verified 2026-11-02, DBeaver 26.2.4, macOS 27.2 |

`postgresql@<version>` also matches the data folder of an older version. Do not offer it until a person confirms that the new version contains the data.
DBngin 27 keeps each server version in `<engine>/<version>` with its programs in `bin`.
DBngin keeps server data in `~/Library/Application Support/com.tinyapp.DBngin/Engines` and server versions in `/Users/Shared/DBngin`.
The MySQL data folder also holds the binary logs.
`PURGE BINARY LOGS` removed the older binary logs. The test table kept its rows. Binary logs can be necessary for replication and for recovery to a point in time.
MySQL writes its error log as `<host name>.err` in its data folder, not in `/opt/homebrew/var/log`.
MongoDB writes logs to `/opt/homebrew/var/log/mongodb`. The MongoDB formula needs `brew trust` for two formulae from the `mongodb/brew` tap.
OpenSearch writes logs to `/opt/homebrew/var/log/opensearch`.
Redis wrote a new log file at its next start. The old log did not come back.
A SQLite database in WAL mode also has `-wal` and `-shm` files. Treat them as part of the database. A file with a `.db` name and no SQLite header is not a SQLite database.
DBeaver, team 42B6MDKMW8. The folder holds the workspace, drivers, and settings.
<!-- rules:end databases -->

Database client applications such as TablePlus and DBeaver store connections and scripts.
Treat their data folders as user data.
Moppo shows the Postgres.app and DBngin data folders under their applications as protected rows with their sizes.
App Uninstaller and Application Leftovers keep these folders. Moppo does not offer them for removal.
Moppo shows `~/Library/DBeaverData` as protected data with DBeaver. App Uninstaller and Application Leftovers keep it.
Without DBeaver, Moppo shows the folder in Hidden & System Data.
Moppo protects a data folder only when the recognition file exists. A folder name alone does not identify a database.
On an Intel Mac, the Homebrew folders are in `/usr/local/var`.
Moppo shows a project folder with SQLite files as a Documents and Files row that needs review. It does not show the database files as rows.
Moppo shows the Homebrew data folders as protected Hidden & System Data rows with their sizes.
Moppo shows `/Users/Shared/DBngin` as a protected Hidden & System Data row when a version folder contains `bin`.
Moppo does not show the SQLite files or `/opt/homebrew/var/log` as rows.

## Other tool storage

These folders belong to tools that no section above covers.

<!-- rules:begin other -->
| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `~/Library/Application Support/multimodal-models` | Download | `ai-coustics/<name>/<model>.aicmodel` files | Never offer | Not possible | Protected | Found 2026-11-03. Not verified. No application identified the folder. #350 checked the protection on the test Mac. |
| `~/.vagrant.d/boxes` | Download | Vagrant layout | `vagrant box remove` after review | `vagrant box add`. A network connection is necessary. | No | Not verified. The user can package a box on this Mac, and the other boxes are multi-gigabyte downloads. |
| `~/.terraform.d/plugin-cache` | Download | Terraform layout | Never offer automatically | Next `terraform init`. A network connection is necessary. | No | Not verified. Working directories link into this cache, so removal breaks them until the next `terraform init`. |

The #216 checks found an ai-coustics audio model here. No application identified it as its own.
<!-- rules:end other -->

## Rows that remain not verified

| Row | Reason |
| --- | --- |
| Herd, OrbStack, JetBrains IDE folders, and Android Studio caches | The apps need the desktop session. |
| Valet | `valet install` changes the DNS resolver and the `sudoers` file. It also starts services as the root user. |
| The .NET SDK folder | The test did not run the official uninstall tool, which needs administrator rights. |
| DBngin server versions | Removal and restore need the DBngin app in the desktop session. |
| Elasticsearch | Homebrew core has no Elasticsearch formula. |
