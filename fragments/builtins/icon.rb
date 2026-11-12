class MochiIcons
  # Returns trusted inline SVG markup for a build-selected icon asset. The
  # compiler copies only icon names referenced by the app into mochi-icons/.
  # Templates must wrap this in Mochi.raw because ordinary values stay text.
  def self.icon(name)
    safe_name = name.to_s.downcase
    safe_name = "circle" if safe_name.empty?
    %Q{<svg class="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><use href="mochi-icons/#{safe_name}.svg#mochi-icon"></use></svg>}
  end
end
