class AppRouter
  # One route declaration and navigation surface for GVM applications.
  # `build` returns the route table; the shell owns that Hash so this helper
  # never needs class instances or hidden global state.
  def self.build
    {
      "routes" => [],
      "not_found" => nil
    }
  end

  def self.split_segments(path)
    pieces = path.to_s.split("?")
    text = pieces[0]
    if text == nil
      text = ""
    end
    parts = text.split("/")
    segments = []
    parts.each do |part|
      if part != ""
        segments << part
      end
    end
    segments
  end

  def self.match_segments(pattern, actual)
    if pattern.length != actual.length
      return nil
    end
    params = {}
    index = 0
    while index < pattern.length
      expected = pattern[index]
      value = actual[index]
      if expected.start_with?(":")
        params[expected.sub(":", "")] = value
      elsif expected != value
        return nil
      end
      index = index + 1
    end
    params
  end

  def self.on(router, path_pattern, screen)
    router["routes"] << {
      "segments" => split_segments(path_pattern),
      "screen" => screen
    }
  end

  def self.not_found(router, screen)
    router["not_found"] = screen
  end

  def self.push(path)
    Mochi.navigate(path.to_s)
  end

  def self.replace(path)
    Mochi.replace_route(path.to_s)
  end

  # Resolves the current URL when no payload is given. Route hosts pass the
  # structured payload delivered to `on_route` so back/forward and direct
  # navigation use the same path, parameter, and query semantics.
  def self.resolve(router, route = nil)
    info = route
    if info == nil
      info = Mochi.route_info
    end
    if info == nil
      info = {}
    end

    path = info["path"]
    segments = info["segments"]
    query = info["query"]
    if segments == nil
      segments = split_segments(path)
    end
    if query == nil
      query = {}
    end

    routes = router["routes"]
    route_index = 0
    while route_index < routes.length
      candidate = routes[route_index]
      params = match_segments(candidate["segments"], segments)
      if params != nil
        return {
          "screen" => candidate["screen"],
          "params" => params,
          "query" => query,
          "path" => path,
          "matched" => true,
          "not_found" => false
        }
      end
      route_index = route_index + 1
    end

    {
      "screen" => router["not_found"],
      "params" => {},
      "query" => query,
      "path" => path,
      "matched" => false,
      "not_found" => true
    }
  end
end
