# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require "fileutils"

require_relative "batteries/fragment_loader"

class Initializer
  extend T::Sig

  sig { params(project_name: String).void }
  def initialize(project_name)
    puts "Init '#{project_name}'"

    proj_path = "./#{project_name}"

    if Dir.exist?(proj_path)
      puts "Aborting, project '#{project_name}' already exists..."
    else
      FileUtils.mkdir_p(proj_path)
      src_path = "#{proj_path}/lib"
      FileUtils.mkdir_p(src_path)

      File.write("#{proj_path}/Taskfile.yml", generate_taskfile)
      File.write("#{proj_path}/Gemfile", generate_gemfile)
      File.write("#{proj_path}/index.html", generate_index_html)
      File.write("#{proj_path}/dev_server_config.json", generate_dev_server_config)
      File.write("#{proj_path}/README.md", generate_readme)
      File.write("#{src_path}/MyCounter.rb", generate_my_first_mochi_component)
    end
  end

  sig { returns(String) }
  def generate_taskfile
    "-" * 80
  end

  sig { returns(String) }
  def generate_gemfile
    <<~TEXT
      source "https://rubygems.org"

      gem "opal", "~> 1.8"
      gem "opal-browser", "~> 0.3.5"

      gem 'sorbet', :group => :development
      gem 'sorbet-runtime'
      gem 'tapioca', require: false, :group => [:development, :test]
    TEXT
  end

  sig { returns(String) }
  def generate_readme
    <<~TEXT
      # Mochi Starter

      The Official Documentation for Mochi can be found under: https://mochirb.com/docs

      ## Getting Started

      ### Building the project
      In order to build the project you can run `mochi -i "./" -o "./build"` alternatively `task build` has already been preconfigured.

      This will produce the 2 build artifacts:
      * `./build/bundle.js` - contains your components
      * `./build/runtime.js` - the opal runtime

      ### Starting the Dev Server
      Mochi ships with a built-in dev server which can be started with
      ```
      mochi dev --config=./dev_server_config.json --root=./
      ```
      by default it is be accessible under: http://127.0.0.1:27490

    TEXT
  end

  sig { returns(String) }
  def generate_dev_server_config
    <<~TEXT
      {
        "routes": {
          "/": "index.html"
        }
      }
    TEXT
  end

  sig { returns(String) }
  def generate_index_html
    <<~HTML
      <html>
          <head>
              <title>Mochi Starter</title>
              <script
                src="./build/runtime.js"
                onload='Opal.require("native"); Opal.require("promise"); Opal.require("browser/setup/full");'></script>
              <script src="./build/bundle.js"></script>
              <link rel="preconnect" href="https://fonts.googleapis.com">
              <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
              <link href="https://fonts.googleapis.com/css2?family=Caprasimo&display=swap" rel="stylesheet">
              <style>
                  body {
                      background: #24262c;
                  }
                  .logo-block {
                      display: flex;
                      justify-content: center;
                      gap: 22px;
                      align-items: anchor-center;
                      color: white;
                      width: 100%;
                      font-family: "Caprasimo", serif;
                      font-weight: 400;
                      font-style: normal;
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

  sig { returns(String) }
  def generate_my_first_mochi_component
    FragmentLoader.load("my_counter_rb")
  end
end
