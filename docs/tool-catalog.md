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
| Moppo today | `Row` for a dedicated row. `Caches` for the general cache scan of `~/Library/Caches`, `~/Library/Logs`, and `~/.cache`. `Hidden` for the general Hidden System Data row of a large home folder. Moppo can move that folder to the Trash after review. `Protected` for a Hidden System Data row that shows the folder size and refuses removal. `Size` for the storage breakdown only. `No` for no coverage. A ticket number for planned work. |
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

| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `~/go/pkg/mod` | Download | `cache/download` folder inside. Folders and files are read-only. | `go clean -modcache` | `go mod download`. A network connection is necessary. | Row | Verified 2026-11-02, Go 1.27.3, macOS 27.2 |
| `~/Library/Caches/go-build` | Cache | `README` and hashed folders | Trash | Next build, without a network connection | Row | Verified 2026-11-02, Go 1.27.3, macOS 27.2 |
| `~/Library/Caches/gopls` | Cache | Folder name and owner | Trash | Next `gopls` run | Caches | Verified 2026-11-02, gopls 0.24.0, macOS 27.2 |
| `~/Library/Caches/golangci-lint` | Cache | Folder name and owner | `golangci-lint cache clean` | Next lint run | Caches | Verified 2026-11-02, golangci-lint 2.15.0, macOS 27.2 |
| `~/go/bin` | Installed | Executable files | Never remove automatically | `go install` | No | Verified 2026-11-02, Go 1.27.3, macOS 27.2 |
| `~/.goenv/versions/<version>` | Installed | `goenv list` | `goenv uninstall <version> --yes` | `goenv install <version> --yes` | Protected | Verified 2026-11-02, goenv 3.2.2, macOS 27.2 |
| `~/.goenv/shared/go-mod` | Download | `cache/download` folder inside | Trash | `goenv install <version> --yes`. A network connection is necessary. | Row | Verified 2026-11-03, goenv 3.2.2, macOS 27.2 |
| `~/.goenv/releases-cache.json` | Cache | goenv layout | Trash | Next `goenv install` | Row | Verified 2026-11-03, goenv 3.2.2, macOS 27.2 |
| `<project>/vendor` | Download | `vendor/modules.txt`, `go.mod`, and `go.sum` | Trash, only if Git does not track it | `go mod vendor`. It works without a network connection when the module cache contains the modules. | Row | Verified 2026-11-02, Go 1.27.3, macOS 27.2 |

goenv 3 installs default tools, such as `gopls` and `staticcheck`, into each version.
It keeps their modules in `~/.goenv/shared/go-mod`, 1.1 GiB in the test.
That folder stays after `goenv uninstall`.
The installed tools ran after the removal of `~/.goenv/shared/go-mod`.
`goenv install --list` and `goenv refresh` did not write `releases-cache.json` again. The next `goenv install` wrote it.
Moppo shows `~/.goenv` as a protected Hidden System Data row. Moppo offers only `shared/go-mod` and `releases-cache.json` in it.
`goenv uninstall` without `--yes` asks for confirmation and skips the removal when no terminal answers.

## Rust

| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `~/.cargo/registry` | Download | `CACHEDIR.TAG`, and `index`, `cache`, and `src` folders | Trash | Next build. A network connection is necessary. | Row | Verified 2026-11-02, Cargo 1.99.1, macOS 27.2 |
| `~/.cargo/git` | Download | `CACHEDIR.TAG`, and `db` and `checkouts` folders | Trash | Next build. A network connection is necessary. | Row | Verified 2026-11-02, Cargo 1.99.1, macOS 27.2 |
| `~/.cargo/bin` | Installed | Executable files. It also contains the `rustup` proxies. | Never remove automatically | `cargo install` | No | Verified 2026-11-02, Cargo 1.99.1, macOS 27.2 |
| `~/.rustup/toolchains/<name>` | Installed | `rustup toolchain list` | `rustup toolchain uninstall <name>` | `rustup toolchain install <name>` | Protected | Verified 2026-11-02, rustup 1.29.2, macOS 27.2 |
| `~/.rustup/downloads`, `~/.rustup/tmp` | Cache | Folder location | Trash | Not necessary | Row | Verified 2026-11-02, rustup 1.29.2, macOS 27.2 |
| `~/Library/Caches/Mozilla.sccache` | Cache | Folder name | Trash | Next build | Caches | Verified 2026-11-02, sccache 0.19.0, macOS 27.2 |
| `<project>/target` | Build | `Cargo.lock` beside the folder. `CACHEDIR.TAG` inside. | Trash | `cargo build`. It works without a network connection when the registry contains the crates. | Row | Verified 2026-11-02, Cargo 1.99.1, macOS 27.2 |

Keep the default toolchain and each toolchain that a `rust-toolchain.toml` file names.

> **Warning:** Moppo can move all of `~/.rustup` to the Trash after review.
> After that move, `cargo` and `rustc` stop working.
> `rustup default stable` downloads the default toolchain again. Other toolchains do not come back.

## PHP

| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
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

Herd and Valet can contain site settings, certificates, and database services.
Composer 2.11.1 keeps its home in `~/.composer` and its cache in `~/Library/Caches/composer` on macOS.
`~/.composer` can contain `auth.json` with registry tokens. Moppo shows it as a protected Hidden System Data row.
Moppo shows Laravel and Symfony project folders as general Documents and Files rows. It does not select them.
Laravel wrote a new log file and a new `storage/logs` folder at the next log entry.
After a Trash move of the complete folder, `storage/logs/.gitignore` did not come back.
Moppo 0.6.0 includes the verified `vendor` rows from #256. The scanner hides project folders smaller than 1 MiB.

## Perl

| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `~/.cpanm/work`, `~/.cpanm/build.log` | Cache | Folder location | Trash | Next install | Row | Verified 2026-11-02, cpanm from Homebrew, macOS 27.2 |
| `~/perl5/lib/perl5` | Installed | `local::lib` layout | Never remove automatically | `cpanm --local-lib=~/perl5 <module>`. A network connection is necessary. | No | Verified 2026-11-03, cpanm from Homebrew, macOS 27.2 |
| `~/perl5/perlbrew/perls/<version>` | Installed | `perlbrew list` | `perlbrew uninstall <version>` | `perlbrew install <version>` | No | Verified 2026-11-02, perl-5.44.0 through perlbrew, macOS 27.2 |
| `~/perl5/perlbrew/build`, `~/perl5/perlbrew/dists` | Cache | perlbrew layout | `perlbrew clean` | Next install | No | Verified 2026-11-02, perlbrew, macOS 27.2 |
| `~/.plenv/versions/<version>` | Installed | `plenv versions` | `plenv uninstall -f <version>` | `plenv install <version>` | Protected | Verified 2026-11-03, plenv 2.3.1 with perl-build 1.34 and Perl 5.44.0, macOS 27.2 |
| `~/.plenv/build` | Cache | plenv layout | Trash | Not necessary | Row | Verified 2026-11-03, plenv 2.3.1, macOS 27.2 |
| `~/.plenv/cache` | Download | Perl source archives in the plenv layout | Trash | Next `plenv install`. A network connection is necessary. | Row | Verified 2026-11-03, plenv 2.3.1, macOS 27.2 |
| `<project>/local` | Download | `cpanfile.snapshot` beside the folder | Trash, only if Git does not track it | `carton install` | No | Verified 2026-11-02, Carton, macOS 27.2 |

After one Perl build, `~/perl5/perlbrew/build` used 229 MiB. `perlbrew clean` removed it.
After one Perl build, `~/.plenv/build` used 229 MiB and `~/.plenv/cache` used 20 MiB. Perl ran after their removal.
`carton` stopped after the removal of `~/perl5/lib/perl5`. `cpanm` restored the modules.
The Perl in macOS has its own copy of some modules, such as `Try::Tiny`. Test a removal with a module that only `~/perl5` contains.
Moppo does not show `~/perl5`. The general hidden folder row includes only hidden folders.

## Python

Moppo has rows for the pip, uv, Poetry, and Pipenv caches.
Project `.venv` folders, `__pycache__`, and tagged analysis caches also have rows.
In the 2026-11-02 test, Moppo offered `~/Library/Caches/pip`, `~/Library/Caches/pypoetry/cache`, and `~/Library/Caches/pypoetry/artifacts`.

| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `~/.pyenv/versions/<version>` | Installed | `pyenv versions` | `pyenv uninstall -f <version>` | `pyenv install <version>` | Protected | Verified 2026-11-02, pyenv 2.8.14, macOS 27.2 |
| `~/miniconda3/pkgs`, `~/anaconda3/pkgs`, `~/miniforge3/pkgs` | Download | `conda info` | `conda clean --all` | Next install | No | Verified 2026-11-02 for `~/miniforge3`, conda 26.9.4, macOS 27.2 |
| `~/miniconda3/envs/<name>` and equivalent folders | Installed | `conda env list` | `conda env remove --name <name>` after review | `conda env create` from an environment file | No | Verified 2026-11-02 for `~/miniforge3`, conda 26.9.4, macOS 27.2 |
| `~/Library/Caches/pypoetry/virtualenvs` | Installed | Poetry layout | Trash after review | `poetry install` with `poetry.lock` | No | Verified 2026-11-02, Poetry 2.5.1, macOS 27.2 |
| `~/Library/Application Support/pipx/venvs` | Installed | `pipx list` | `pipx uninstall <package>` | `pipx install <package>` | No | Verified 2026-11-02, pipx 1.18.11, macOS 27.2 |
| `~/.cache/pre-commit` | Cache | Folder location | `pre-commit clean` | Next hook run. A network connection is necessary. | Caches | Verified 2026-11-02, pre-commit 4.7.0, macOS 27.2 |
| `~/Library/Logs/pipx` | Logs | Folder location | Trash after review | Not possible | Caches, review required | Verified 2026-11-03, pipx 1.18.11, macOS 27.2 |

pipx 1.18 uses `~/Library/Application Support/pipx` on macOS. The path `~/.local/pipx` is from older pipx versions.
pipx creates `~/Library/Logs/pipx` again at the next command. The old logs do not come back.
Moppo 0.6.0 offered `~/Library/Logs/pipx` as safe, because it treated `~/Library/Logs` as a cache folder.
Since #336, Moppo shows each item in `~/Library/Logs` as **Not regenerable**. **Safe to Remove** does not select these items.
`conda clean --all` did not damage existing environments.
pyenv can build Python 3.12 only with OpenSSL 3. When Homebrew has OpenSSL 4, set `PYTHON_BUILD_HOMEBREW_OPENSSL_FORMULA=openssl@3`.

## Ruby

Moppo has a row for the Bundler cache in `~/.bundle/cache`.

| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `~/.local/share/gem` | Installed | `gem list` | `gem uninstall --user-install <gem>` | `gem install --user-install <gem>` | Protected | Verified 2026-11-02, RubyGems 3.5.22, macOS 27.2 |
| `~/.gem` | Installed | `gem list` | `gem uninstall <gem>` | `gem install <gem>` | No | Not created by RubyGems 3.5.22 |
| `~/.rbenv/versions/<version>` | Installed | `rbenv versions` | `rbenv uninstall -f <version>` | `rbenv install <version>` | Protected | Verified 2026-11-02, Ruby 3.3.13 through rbenv, macOS 27.2 |
| `~/.rvm/rubies/<version>` | Installed | `rvm list` | `rvm remove <version>` | `rvm install <version>` | Protected | Verified 2026-11-03, RVM 1.29.12-next with Ruby 3.3.13, macOS 27.2 |
| `~/.rvm/archives`, `~/.rvm/src` | Cache | RVM layout | `rvm cleanup all` | Next install. A network connection is necessary. | Protected | Verified 2026-11-03, RVM 1.29.12-next, macOS 27.2 |
| `~/.rubies/<version>` | Installed | chruby lists the folder | Trash after review | `ruby-install ruby <version>` | Protected | Verified 2026-11-03, chruby 0.3.9 and ruby-install 0.10.2, macOS 27.2 |
| `~/src/ruby-<version>`, `~/src/ruby-<version>.tar.xz` | Cache | ruby-install layout and a matching folder in `~/.rubies` | Trash | Not necessary | No | Verified 2026-11-03, ruby-install 0.10.2, macOS 27.2 |
| `~/.cache/ruby-install` | Cache | Folder location | Trash | Next `ruby-install` run | Caches | Verified 2026-11-03, ruby-install 0.10.2, macOS 27.2 |
| `~/.gnupg` | User data | GnuPG layout | Never offer | Not possible | Protected | Found 2026-11-03, GnuPG 2.5.24, macOS 27.2 |
| `<project>/vendor/bundle` | Download | `Gemfile.lock` beside `vendor`, and `BUNDLE_PATH` in `.bundle/config` | Trash, only if Git does not track it | `bundle install`. A network connection is necessary. | Row | Verified 2026-11-02, Bundler 2.5.22, macOS 27.2 |

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

| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `~/.m2/repository` | Download | Maven layout | Trash | Next Maven build. A network connection is necessary. | Row | Verified 2026-11-02, Maven 3.10.0, macOS 27.2 |
| `~/.gradle/daemon` | Logs | Gradle layout | Trash when no Gradle daemon runs | Next build | No | Verified 2026-11-02, Gradle 9.8.2, macOS 27.2 |
| `~/.sbt/boot` | Download | sbt layout | Trash | Not necessary for sbt 2 | Row | Verified 2026-11-02, sbt 2.0.12, macOS 27.2 |
| `~/Library/Caches/Coursier` | Download | Folder name | Trash | Next sbt run. A network connection is necessary. | Row | Verified 2026-11-03, sbt 2.0.12, macOS 27.2 |
| `~/.sdkman/candidates/<tool>/<version>` | Installed | `sdk list` | `sdk uninstall <tool> <version>` | `sdk install <tool> <version>` | Protected | Verified 2026-11-02, jbang 0.143.0 through SDKMAN, macOS 27.2 |
| `~/.sdkman/tmp` | Cache | SDKMAN layout | `sdk flush` | Next install | Protected | Verified 2026-11-02, macOS 27.2 |
| `~/.sdkman/archives` | Cache | SDKMAN layout | `sdk flush` | Next install | Protected | Not created in the 2026-11-02 test |
| `~/.konan` | Download | `dependencies` folder with the Kotlin/Native LLVM and `libffi` | Trash | Next `kotlinc-native` build. A network connection is necessary. | Hidden | Verified 2026-11-03, Kotlin/Native 2.4.21, macOS 27.2 |
| `<project>/target` | Build | `pom.xml` beside the folder | Trash | `mvn package`. It works without a network connection when the repository contains the dependencies. | Row | Verified 2026-11-02, Maven 3.10.0, macOS 27.2 |
| `~/Library/Caches/JetBrains/<product><version>` | Cache | Older version than the installed IDE | Trash | Next IDE start | Caches | Not verified. The IDE needs the desktop session. |
| `~/Library/Application Support/JetBrains/<product><version>` | User data | IDE settings | Never offer | Not possible | No | Not verified. The IDE needs the desktop session. |

`~/.m2` can contain `settings.xml` with repository passwords. Moppo protects `~/.m2` and offers only `~/.m2/repository` for review.
sbt 2 compiled after the removal of `~/.sbt/boot` and did not create it again.
sbt 2 downloaded the 133 MiB Coursier cache again in 6 seconds.
SDKMAN needs Bash 4 or later. Install a newer Bash before you install SDKMAN on macOS.
The project scanner hides a `target` folder that is smaller than 1 MiB.
The test used the `kotlinc-native` compiler from the official release archive. It downloaded 688 MiB into `~/.konan/dependencies`.
The test did not use the Kotlin Gradle plugin.

## Android

| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `~/Library/Android/sdk/system-images` | Download | `sdkmanager --list_installed` | `sdkmanager --uninstall <package>` | `sdkmanager <package>` | Protected | Verified 2026-11-02, system image android-36 arm64, macOS 27.2 |
| `~/Library/Android/sdk/ndk/<version>` | Download | `sdkmanager --list_installed` | `sdkmanager --uninstall <package>` | `sdkmanager <package>` | Protected | Verified 2026-11-03, NDK 30.0.16248370, macOS 27.2 |
| `~/Library/Android/sdk/build-tools/<version>` | Download | `sdkmanager --list_installed` | `sdkmanager --uninstall <package>` | `sdkmanager <package>` | Protected | Verified 2026-11-02, build tools 37.0.0, macOS 27.2 |
| `~/Library/Android/sdk/emulator` | Download | `sdkmanager --list_installed` | `sdkmanager --uninstall emulator` | `sdkmanager emulator` | Protected | Verified 2026-11-03, emulator 37.2.13, macOS 27.2 |
| `~/.android/avd` | User data | `avdmanager list avd` | `avdmanager delete avd --name <name>` after review | Create the emulator again | Protected | Verified 2026-11-02 for an AVD that never started, macOS 27.2 |
| `~/.android/cache` | Cache | Folder location | Trash | Not necessary | Row | Verified 2026-11-02, cmdline-tools from Homebrew, macOS 27.2 |
| `~/Library/Caches/Google/AndroidStudio<version>` | Cache | Older version than the installed IDE | Trash | Next IDE start | Caches | Not verified. Android Studio needs the desktop session. |

Emulator images contain installed apps and test data. Treat them as user data until verification.
The tested AVD never started, so it contained no apps or data.
Moppo shows `~/Library/Android/sdk` as one protected Hidden System Data row. The SDK used about 9 GB in this test. The NDK used 2.8 GiB of it.
Moppo does not offer SDK packages because only `sdkmanager` removes them correctly.
`~/.android/avd` stayed after the removal of the emulator package.
The Homebrew `avdmanager` does not find an SDK in `~/Library/Android/sdk`. Use `cmdline-tools;latest` from that SDK.
`sdkmanager` did not create `~/.android/cache` again after its removal.

## .NET

Moppo has a row for NuGet packages in `~/.nuget/packages`.

| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `~/.nuget/packages` | Download | `dotnet nuget locals global-packages --list` | Trash | Next restore. A network connection is necessary. | Row | Verified 2026-11-02, .NET SDK 10.0.403, macOS 27.2 |
| `~/.local/share/NuGet/http-cache` | Cache | `dotnet nuget locals http-cache --list` | `dotnet nuget locals http-cache --clear` | Next restore | Protected | Verified 2026-11-02, .NET SDK 10.0.403, macOS 27.2 |
| `/usr/local/share/dotnet/sdk/<version>` | Installed | `dotnet --list-sdks` | Official uninstall tool after review | Install the SDK again | No | Found 2026-11-02, .NET SDK 10.0.403. Not verified. The uninstall tool needs administrator rights. |
| `<project>/bin`, `<project>/obj` | Build | `.csproj` or `.fsproj` beside the folders | Trash | `dotnet build` | #49 | Verified 2026-11-02, .NET SDK 10.0.403, macOS 27.2 |

The Homebrew `dotnet-sdk` cask installs the SDK in `/usr/local/share/dotnet`, also on Apple silicon.
Moppo shows `~/.local/share/NuGet` as a protected Hidden System Data row at any size. It does not offer the HTTP cache, because the catalog verified only the `dotnet` command.

## Elixir, Erlang, and Haskell

Moppo has rows for Hex packages and Cabal packages.
In the 2026-11-02 test, Moppo offered `~/.hex/packages`.

| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `<project>/_build` | Build | `mix.exs` beside the folder | Trash | `mix compile` | #49 | Verified 2026-11-02, Elixir 1.20.5, macOS 27.2 |
| `<project>/deps` | Download | `mix.lock` beside the folder | Trash | `mix deps.get`. A network connection is necessary. | No | Verified 2026-11-02, Elixir 1.20.5, macOS 27.2 |
| `~/.mix/archives` | Installed | Mix layout | Never remove automatically | `mix local.hex --force` | Protected | Verified 2026-11-03, Hex 2.6.0 with Elixir 1.20.5, macOS 27.2 |
| `~/.ghcup/ghc/<version>` | Installed | `ghcup list` | `ghcup rm ghc <version>` | `ghcup install ghc <version>` | Protected | Verified 2026-11-02, GHC 9.10.3 through ghcup 0.2.6.2, macOS 27.2 |
| `~/.ghcup/cache` | Cache | ghcup layout | `ghcup gc --cache` | Next install | Protected | Verified 2026-11-02, ghcup 0.2.6.2, macOS 27.2 |
| `~/.cache/cabal` | Download | cabal layout | Trash after review | `cabal update` and the next build. A network connection is necessary. | Row, review required | Verified 2026-11-03, cabal 3.16.1.0, macOS 27.2 |
| `~/.local/state/cabal/store` | Installed | cabal layout | Trash after review | Next build for project dependencies | Protected | Verified 2026-11-03, cabal 3.16.1.0, macOS 27.2 |
| `~/.stack/programs/<platform>/ghc-<version>` | Installed | Stack layout | Trash after review | Next `stack build`. A network connection is necessary. | Protected | Verified 2026-11-03, Stack 3.11.1 with GHC 9.10.3, macOS 27.2 |
| `~/.stack/snapshots` | Build | Stack layout | Trash | Next `stack build` | Row | Verified 2026-11-03, Stack 3.11.1, macOS 27.2 |
| `~/.stack/pantry`, `~/.stack/setup-exe-cache` | Download | Stack layout | Trash | Next `stack build`. A network connection is necessary. | Row | Verified 2026-11-03, Stack 3.11.1, macOS 27.2 |
| `~/.stack/config.yaml` | User data | Stack layout | Never offer | Not possible | Protected | Verified 2026-11-03, Stack 3.11.1, macOS 27.2 |
| `<project>/dist-newstyle` | Build | `.cabal` file beside the folder | Trash | `cabal build` | No | Verified 2026-11-02, cabal 3.16.1.0, macOS 27.2 |
| `<project>/.stack-work` | Build | `stack.yaml` beside the folder | Trash | `stack build` | No | Verified 2026-11-03, Stack 3.11.1, macOS 27.2 |

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

| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `~/.asdf/installs/<tool>/<version>` | Installed | `asdf list` | `asdf uninstall <tool> <version>` | `asdf install <tool> <version>` | Protected | Verified 2026-11-02, asdf 0.20.2, macOS 27.2 |
| `~/.asdf/downloads` | Cache | asdf layout | Trash | Next install | Row | Verified 2026-11-02, asdf 0.20.2, macOS 27.2 |
| `~/.local/share/mise/installs/<tool>/<version>` | Installed | `mise ls` | `mise uninstall <tool>@<version>` | `mise install <tool>@<version>` | Protected | Verified 2026-11-02, mise 2026.10.25, macOS 27.2 |
| `~/Library/Caches/mise` | Cache | Folder name | `mise cache clear` | Next install | Caches | Verified 2026-11-02, mise 2026.10.25, macOS 27.2 |

Keep each version that a `.tool-versions` or `mise.toml` file in a project names.
Moppo shows `~/.asdf` as a protected Hidden System Data row when it is larger than 5 MiB. Moppo offers only `~/.asdf/downloads` in it.
Moppo shows `~/.local/share/mise` as a protected Hidden System Data row when it contains `installs`.

## Container and virtual machine tools

Moppo reviews Docker images and the Docker build cache through Docker.

| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `~/.colima` | User data | Colima installed | `colima delete` after review | Not possible for volumes after `colima delete --data` | Protected | Verified 2026-11-02, Colima 0.10.3, macOS 27.2 |
| `~/.colima/_lima/_disks/<profile>` | User data | Colima layout | `colima delete --data` after review | Not possible | Protected | Verified 2026-11-02, Colima 0.10.3, macOS 27.2 |
| `~/.lima/<instance>` | User data | `limactl list` | `limactl delete <instance>` after review | Not possible | Protected | Verified 2026-11-03, Lima 2.2.1, macOS 27.2 |
| `~/.lima/_config` | User data | Lima layout. It contains the `user` SSH key. | Never offer | Not possible | Protected | Verified 2026-11-03, Lima 2.2.1, macOS 27.2 |
| `~/Library/Caches/lima` | Download | `download/by-url-sha256` folder inside | Trash | Next `limactl start` of a new instance. A network connection is necessary. | Caches | Verified 2026-11-03, Lima 2.2.1, macOS 27.2 |
| `~/.orbstack` | User data | OrbStack installed | OrbStack settings after review | Not possible for volumes | No | Not verified. The OrbStack app needs a first start in the desktop session. |
| `~/.local/share/containers/podman/machine` | User data | Podman installed | `podman machine rm` after review | Not possible for volumes | Protected | Verified 2026-11-02, Podman 6.1.4, macOS 27.2 |
| `~/.local/share/containers/podman/machine/applehv/cache` | Download | Podman layout | Trash | `podman machine init`. A network connection is necessary. | Row | Verified 2026-11-03, Podman 6.1.4, macOS 27.2 |

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

## Databases

Database files are user data. Moppo must never offer them for removal.
If you remove a file while the server runs, you can damage the database.
Only the tool can remove its own logs and old data safely.

| Path | Type | Recognition | Removal | Restore | Moppo today | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `/opt/homebrew/var/postgresql@<version>`, `/opt/homebrew/var/postgres` | User data | `PG_VERSION` file | Never offer | Not possible | Hidden & System Data, protected | Verified 2026-11-02 for `postgresql@18`, PostgreSQL 18.6, macOS 27.2 |
| `~/Library/Application Support/Postgres/var-<version>` | User data | Postgres.app installed and `PG_VERSION` file | Never offer | Not possible | Applications, protected | Verified 2026-11-02, Postgres.app 2.9.6 with PostgreSQL 18, macOS 27.2 |
| `~/Library/Application Support/com.tinyapp.DBngin/Engines/<engine>/<id>` | User data | DBngin installed and a database file in the engine folder, such as `ibdata1` or `PG_VERSION` | Never offer | Not possible | Applications, protected | Verified 2026-11-02, DBngin 27.0.2 with MySQL 9.7.2, macOS 27.2 |
| `/Users/Shared/DBngin/<engine>/<version>` | Installed | DBngin installed. A `bin` folder with the server programs. | DBngin, after review | DBngin downloads the version again | Protected | Found 2026-11-02, DBngin 27.0.2. Not verified. Removal and restore need the DBngin app in the desktop session. |
| `/opt/homebrew/var/mysql` | User data | `ibdata1` or `mysql` folder | Never offer | Not possible | Hidden & System Data, protected | Verified 2026-11-02, MySQL 26.10, macOS 27.2 |
| MySQL binary logs in the data folder | User data | `binlog.<number>` files and `binlog.index` | `PURGE BINARY LOGS` in MySQL after review | Not possible | Protected in the MySQL data row | Verified 2026-11-03, MySQL 26.10, macOS 27.2 |
| `/opt/homebrew/var/mongodb` | User data | `WiredTiger` files | Never offer | Not possible | Hidden & System Data, protected | Verified 2026-11-02, MongoDB 9.0.4, macOS 27.2 |
| `/opt/homebrew/var/db/redis` | User data | `dump.rdb` or `appendonly` files | Never offer | Not possible | Hidden & System Data, protected | Verified 2026-11-02, Redis 8.10.3, macOS 27.2 |
| `/opt/homebrew/var/lib/opensearch` | User data | `nodes/<number>/_state` folder | Never offer | Not possible | Hidden & System Data, protected | Verified 2026-11-02, OpenSearch 3.9.0, macOS 27.2 |
| `/opt/homebrew/var/lib/elasticsearch` | User data | `nodes/<number>/_state` or `_state` folder | Never offer | Not possible | Hidden & System Data, protected | Not verified. Homebrew core has no Elasticsearch formula. |
| `/opt/homebrew/var/log` | Logs | Service log files | Trash after review, when the service does not run | Not possible | No | Verified 2026-11-03, Redis 8.10.3, macOS 27.2 |
| `<project>/*.sqlite`, `<project>/*.sqlite3`, `<project>/*.db` | User data | `SQLite format 3` header | Never offer | Not possible | No | Verified 2026-11-03, SQLite 3.54.0, macOS 27.2 |
| `~/Library/DBeaverData` | User data | `workspace6/<project>/.dbeaver/data-sources.json` | Never offer | Not possible | Applications, protected. Hidden & System Data, protected, without DBeaver | Verified 2026-11-02, DBeaver 26.2.4, macOS 27.2 |

Database client applications such as TablePlus and DBeaver store connections and scripts.
Treat their data folders as user data.
DBngin keeps server data in `~/Library/Application Support/com.tinyapp.DBngin/Engines` and server versions in `/Users/Shared/DBngin`.
Moppo shows the Postgres.app and DBngin data folders under their applications as protected rows with their sizes.
App Uninstaller and Application Leftovers keep these folders. Moppo does not offer them for removal.
Moppo shows `~/Library/DBeaverData` as protected data with DBeaver. App Uninstaller and Application Leftovers keep it.
Without DBeaver, Moppo shows the folder in Hidden & System Data.
Moppo protects a data folder only when the recognition file exists. A folder name alone does not identify a database.
On an Intel Mac, the Homebrew folders are in `/usr/local/var`.
Older PostgreSQL data folders can remain after an upgrade.
Do not offer them until a person confirms that the new version contains the data.
MySQL writes its error log as `<host name>.err` in its data folder, not in `/opt/homebrew/var/log`.
`PURGE BINARY LOGS` removed the older binary logs. The test table kept its rows.
Binary logs can be necessary for replication and for recovery to a point in time.
MongoDB writes logs to `/opt/homebrew/var/log/mongodb`. OpenSearch writes logs to `/opt/homebrew/var/log/opensearch`.
Redis wrote a new log file at its next start. The old log did not come back.
A SQLite database in WAL mode also has `-wal` and `-shm` files. Treat them as part of the database.
A file with a `.db` name and no SQLite header is not a SQLite database.
Moppo shows a project folder with SQLite files as a Documents and Files row that needs review. It does not show the database files as rows.
Moppo shows the Homebrew data folders as protected Hidden & System Data rows with their sizes.
Moppo shows `/Users/Shared/DBngin` as a protected Hidden & System Data row when a version folder contains `bin`.
Moppo does not show the SQLite files or `/opt/homebrew/var/log` as rows.
The MongoDB formula needs `brew trust` for two formulae from the `mongodb/brew` tap.

## Rows that remain not verified

| Row | Reason |
| --- | --- |
| Herd, OrbStack, JetBrains IDE folders, and Android Studio caches | The apps need the desktop session. |
| Valet | `valet install` changes the DNS resolver and the `sudoers` file. It also starts services as the root user. |
| The .NET SDK folder | The test did not run the official uninstall tool, which needs administrator rights. |
| DBngin server versions | Removal and restore need the DBngin app in the desktop session. |
| Elasticsearch | Homebrew core has no Elasticsearch formula. |
