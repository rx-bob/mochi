class SortContractsRoot
  @tag_name = "sort-contracts-root"
  @rows
  @ordered_rows
  @sort_key_calls
  @comparison_calls
  @descending
  @ascending
  @edge_cases
  @event_order

  def initialize
    @rows = [
      {name: "third", rank: 3},
      {name: "first", rank: -2},
      {name: "second", rank: 1},
      {name: "last", rank: 4}
    ]
    @sort_key_calls = 0
    @ordered_rows = sorted_rows(@rows)
    @comparison_calls = 0
    @descending = [16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1].sort do |left, right|
      @comparison_calls += 1
      right <=> left
    end
    @ascending = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16].sort do |left, right|
      @comparison_calls += 1
      left <=> right
    end
    @edge_cases = [
      [].sort_by { |value| value },
      [-2].sort_by { |value| value },
      [2, -1, 2, 0, -1].sort_by { |value| value }
    ]
    @event_order = []
  end

  def sorted_rows(rows)
    rows.sort_by do |row|
      @sort_key_calls += 1
      row[:rank]
    end
  end

  def row_names(rows)
    rows.map { |row| row[:name] }.join(",")
  end

  def update_order
    @event_order = [5, -1, 3, 0].sort do |left, right|
      right <=> left
    end
  end

  def invalid_sort
    [3, "not comparable"].sort_by { |value| value }
  end

  def html
    %Q{
      <span class="sorted">{row_names(@ordered_rows)}</span>
      <span class="original">{row_names(@rows)}</span>
      <span class="key-calls">{@sort_key_calls}</span>
      <span class="comparison-calls">{@comparison_calls}</span>
      <span class="descending">{@descending[0]}:{@descending[15]}</span>
      <span class="ascending">{@ascending[0]}:{@ascending[15]}</span>
      <span class="empty-sort">{@edge_cases[0].length}</span>
      <span class="single-sort">{@edge_cases[1][0]}</span>
      <span class="duplicate-sort">{@edge_cases[2].join(",")}</span>
      <span class="event-order">{@event_order.join(",")}</span>
      <button class="update" onclick="{update_order}">Sort descending</button>
      <button class="invalid" onclick="{invalid_sort}">Invalid key</button>
    }
  end
end
