# iseq_loader.rb
require 'optparse'

if ARGV.empty?
  puts "Error: No input file specified."
  exit 1
end

input_file = ARGV[0]

begin
  binary_dump = File.binread(input_file)
  
  # Load the binary back into an InstructionSequence
  iseq = RubyVM::InstructionSequence.load_from_binary(binary_dump)
  
  puts "Successfully loaded: #{iseq.path}"
  
  # Execute the InstructionSequence
  puts "--- Executing ---"
  iseq.eval
  puts "--- Execution Finished ---"
  
  # Verify our component was actually loaded
  if Object.const_defined?(:TestComponent)
    comp = TestComponent.new
    comp.increment
    comp.increment
    puts "Verified runtime: #{comp.render}"
  else
    puts "Error: TestComponent was not defined after evaluating iseq."
  end
  
rescue => e
  puts "Failed to load/evaluate: #{e.message}"
  exit 1
end
