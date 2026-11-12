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
        cmds:
          - mochi -i "./" -o "./build"
      test:
        desc: Run Ruby component behavior tests in the browser
        cmds:
          - mochi test -i "./"
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

    Mochi lets you build browser applications in Ruby. Application components live in `lib/`.

    ## Getting Started

    ### Building the project
    Run `mochi -i "./" -o "./build"` to build, or use `task build`.

    The build contains the Mochi loader, GVM runtime, component descriptors, and `.chi` bytecode.

    ### Testing components
    Add Ruby behavior tests under `test/` with filenames ending in `_test.rb`. Run them with `mochi test` or `task test`.

    Tests use a small Ruby recorder DSL. The framework compiles the app through the normal GVM path, mounts components in a browser, performs actions, waits for a settled render, and checks visible text. Tests run in an isolated temporary bundle and never enter production output.

    ```ruby
    Mochi::Test.test("counter increments") do
      mount "my-counter"
      click "button"
      wait_for_settled
      assert_text "h1", "Count: 1"
    end
    ```

    `assert_text` selectors start in the mounted component's shadow root. Use `>>>` to cross into a child component, for example `"child-counter >>> .value"`.

    ### Starting the Dev Server
    Mochi ships with a built-in dev server which can be started with
    ```
    mochi dev --config=./dev_server_config.json --root=./
    ```
    by default it is be accessible under: http://127.0.0.1:27490

    TEXT
  end

  def generate_dev_server_config : String
    <<-'TEXT'
    {
      "routes": {
        "/": "index.html"
      }
    }
    TEXT
  end

  def generate_index_html : String
    <<-'HTML'
    <html>
        <head>
            <title>Mochi Starter</title>
            <script src="./build/mochi-loader.js"></script>
            <style>
                body {
                    background: #24262c;
                }
                .logo-block {
                    display: flex;
                    justify-content: center;
                    gap: 22px;
                    align-items: center;
                    color: white;
                    width: 100%;
                    font-family: sans-serif;
                }
                .logo { height: 64px; }
            </style>
        </head>
        <body>
            <div class="logo-block">
                <img class="logo" src="https://github.com/yampug/mochi/blob/main/devground/mochi.png?raw=true"/>
                <h1>Hello Mochi</h1>
            </div>
            <div>
                <my-counter count="3"></my-counter>
            </div>
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
