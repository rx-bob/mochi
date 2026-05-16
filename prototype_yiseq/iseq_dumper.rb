# iseq_dumper.rb
require 'optparse'

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: ruby iseq_dumper.rb [options] <file.rb>"

  opts.on("-o", "--out FILE", "Output binary file") do |v|
    options[:out] = v
  end
end.parse!

if ARGV.empty?
  puts "Error: No input file specified."
  exit 1
end

input_file = ARGV[0]
output_file = options[:out] || input_file.sub(/\.rb$/, '.yiseq')

begin
  # 1. Read the Ruby source code (or you can use compile_file directly)
  # 2. Compile it to an InstructionSequence
  iseq = RubyVM::InstructionSequence.compile_file(input_file)
  
  # 3. Convert the sequence to MRI's internal binary format
  binary_dump = iseq.to_binary
  
  # 4. Write it to the output file
  File.binwrite(output_file, binary_dump)
  
  puts "Successfully dumped #{input_file} to #{output_file}"
  puts "Original Size: #{File.size(input_file)} bytes"
  puts "Bytecode Size: #{File.size(output_file)} bytes"
rescue => e
  puts "Failed to compile: #{e.message}"
  exit 1
end
