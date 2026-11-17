require "file_utils"
require "./generated/builtins/my_counter_rb"

class Initializer
  def initialize(project_name : String)
    puts "Init '#{project_name}'"

    proj_path = "./#{project_name}"

    if Dir.exists?(proj_path)
      puts "Aborting, project '#{project_name}' already exists..."
    else
      Dir.mkdir_p(proj_path)
      src_path = "#{proj_path}/lib"
      Dir.mkdir_p(src_path)
      test_path = "#{proj_path}/test"
      Dir.mkdir_p(test_path)

      File.write("#{proj_path}/Taskfile.yml", generate_taskfile)
      File.write("#{proj_path}/.mochi-lint.yml", generate_lint_config)
      File.write("#{proj_path}/Gemfile", generate_gemfile)
      File.write("#{proj_path}/index.html", generate_index_html)
      File.write("#{proj_path}/dev_server_config.json", generate_dev_server_config)
      File.write("#{proj_path}/README.md", generate_readme)
      File.write("#{src_path}/MyCounter.rb", generate_my_first_mochi_component)
      File.write("#{test_path}/counter_test.rb", generate_counter_test)
    end
  end

  def generate_taskfile : String
    <<-'YML'
    version: '3'

    tasks:
      build:
        desc: Build this Ruby application with the installed Mochi compiler
        cmds:
          - mochi -i "./" -o "./build"
      lint:
        desc: Check Ruby sources with this project's lint policy
        cmds:
          - mochi lint -i "./"
      test:
        desc: Run Ruby component behavior tests in the browser
        cmds:
          - mochi test -i "./"
      check:
        desc: Run lint and then Ruby behavior tests
        cmds:
          - task: lint
          - task: test
      dev:
        desc: Serve the built application at http://127.0.0.1:27490
        cmds:
          - mochi dev --config=./dev_server_config.json --root=./
    YML
  end

  def generate_lint_config : String
    <<-'YML'
    version: 1

    # Lint the Ruby that ships in this project. Globs are relative to this file.
    include:
      - "lib/**/*.rb"

    # These are the standard Mochi defaults, plus the opt-in line-length rule
    # enabled for new projects. Adjust the limits or severities when wider
    # lines or packed CSS declarations are intentional.
    rules:
      correctness/unknown-handler: error
      correctness/timer-callback: error
      correctness/child-props: error
      correctness/event-payload: error
      components/prop-write: warning
      metrics/method-length:
        severity: warning
        max: 60
      metrics/line-length:
        severity: warning
        max: 120
      style/css-declaration-lines: warning
      metrics/nesting-depth:
        severity: warning
        max: 4
      metrics/component-methods:
        severity: warning
        max: 40
      accessibility/control-name: warning
      accessibility/keyboard-activation: warning
      templates/unstable-key: off
      migration/css-timer: off
      money/float-to-minor-units: off
    YML
  end

  def generate_gemfile : String
    <<-'TEXT'
    source "https://rubygems.org"

    gem 'sorbet', :group => :development
    gem 'sorbet-runtime'
    TEXT
  end

  def generate_readme : String
    <<-'TEXT'
    # Mochi Starter

    Build browser applications in Ruby. Application components live in `lib/`; behavior tests live in `test/`.

    ## Getting Started

    Install the Mochi development command from a Mochi checkout (see the [Mochi getting-started guide](https://github.com/yampug/mochi/blob/main/AGENTS.md#installing-the-development-command)). The install links the command to that checkout and records its compiler and browser runtime locations. Add the printed `bin` directory to `PATH` if needed.

    From this project directory, run:

    ```sh
    mochi -i . -o ./build
    mochi lint -i .
    mochi test -i .
    mochi dev --config=./dev_server_config.json --root=./
    ```

    Run `task check` to lint the project and then run its Ruby behavior tests. `task lint` reads `.mochi-lint.yml`, which records the standard rule severities and metric limits. `task build` compiles the application without running either check.

    Ordinary compilation and `mochi dev` do not run lint. Run `task lint` or `mochi lint -i .` explicitly, and let `task check` or CI enforce it. See the [lint contract](https://github.com/yampug/mochi/blob/main/references/LINT_CONTRACT.md) for every rule, exit code, and suppression form.

    Open <http://127.0.0.1:27490>. The starter compiles to a GVM bundle: the loader reads a manifest, then loads each component's descriptor and `.chi` bytecode when it is used. No app-authored JavaScript is needed.

    `mochi test` compiles an isolated test bundle and runs Ruby-authored scenarios in Chromium, Firefox, and WebKit. Test sources and runner files do not enter production output. Tests need Node.js, Mochi's Playwright dependencies, and installed Playwright browser binaries; install those once from the Mochi checkout with `cd e2e && npm ci && npx playwright install chromium firefox webkit`. Use `--browsers=chromium` to select an engine or `--test-file=counter_test.rb` to select a file relative to this project's `test/` directory.

    ```ruby
    Mochi::Test.test("counter increments") do
      mount "my-counter"
      click "button"
      wait_for_settled
      assert_text "h1", "Count: 1"
    end
    ```

    `assert_text` selectors start in the mounted component's shadow root. Use `>>>` to cross into a child component, for example `"child-counter >>> .value"`.

    Put shared CSS under `lib/styles/`. From `lib/MyCounter.rb`, use a literal `@import "./styles/controls.css";` before local rules in `def css`; paths are component-relative and resolved at build time. Project-root `styles/` is not staged. `public/` assets keep their `public/` output prefix. Static icons come from your project's `icons/` directory; no icon catalog is bundled implicitly.

    See Mochi's [Ruby examples and contracts](https://github.com/yampug/mochi/blob/main/AGENTS.md#complete-ruby-examples-and-contracts) for computed dependencies, keyed forms/SVG, and optional mount-owned browser APIs. Replace collection roots to publish nested edits; automatic deep mutation observation is not provided. File reads, JSON documents, and downloads have explicit bounds; no application JavaScript or manual adapter tags are needed.

    `index.html` uses a root asset base so the loader and compiled bundle also resolve when a static host serves a deep link. The dev server maps `/deep/entry` to the entry page for this purpose. If deploying under a URL prefix, set the base URL and loader paths to that prefix and configure the host to serve the entry page for application routes. See the [asset path guide](https://github.com/yampug/mochi/blob/main/AGENTS.md#icons).

    TEXT
  end

  def generate_dev_server_config : String
    <<-'TEXT'
    {
      "routes": {
        "/": "index.html",
        "/deep/entry": "index.html"
      }
    }
    TEXT
  end

  def generate_index_html : String
    <<-'HTML'
    <!doctype html>
    <html lang="en">
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>Mochi Starter</title>
            <base href="/">
            <script src="./build/mochi-loader.js" data-mochi-manifest="./mochi-manifest.json"></script>
            <style>
                body {
                    margin: 0;
                    background: #f4f1eb;
                    color: #25231f;
                    font: 18px system-ui, sans-serif;
                }
                .logo-block {
                    display: flex;
                    justify-content: center;
                    gap: 16px;
                    align-items: center;
                    margin: 12vh auto 0;
                }
                .mark { color: #c45b36; font-size: 40px; }
                main { display: grid; justify-items: center; gap: 16px; margin: 40px auto; }
            </style>
        </head>
        <body>
            <div class="logo-block">
                <span class="mark" aria-hidden="true">◆</span>
                <h1>Hello Mochi</h1>
            </div>
            <main><my-counter></my-counter></main>
        </body>
    </html>
    HTML
  end

  def generate_my_first_mochi_component : String
    return MyCounterRbFragment.get_ruby_code
  end

  def generate_counter_test : String
    <<-'RUBY'
    Mochi::Test.test("counter increments") do
      mount "my-counter"
      click "button"
      wait_for_settled
      assert_text "h1", "Count: 1"
    end
    RUBY
  end
end
