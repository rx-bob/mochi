class MochiIcons
  # Returns trusted inline SVG markup for a build-selected icon asset. The
  # loader resolves the compiler-owned resource reference against the bundle
  # manifest, so route and document paths do not affect the icon URL.
  # Templates must wrap this in Mochi.raw because ordinary values stay text.
  def self.icon(name)
    safe_name = name.to_s.downcase
    safe_name = safe_name.gsub("_", "-")
    safe_name = "circle" if safe_name.empty?
    %Q{<svg class="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><use href="__MOCHI_ICON__#{safe_name}__#mochi-icon"></use></svg>}
  end
end
