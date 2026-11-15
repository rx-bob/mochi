class MyCounter

  @tag_name = "my-counter"
  @count

  def initialize
    @count = 0
  end

  def reactables
    ["count"]
  end

  def html
    %Q{
      <div class="wrapper">
        <h1>Count: {@count}</h1>
        <p class="state {box_class}">State</p>
        <p class="mode {if @count > 0}active{end}">Mode</p>
        {if @count > 5}
          <p class="message">🎉 Count is greater than 5!</p>
        {end}
        {if @count > 10}
          <p class="message success">🚀 Wow! Greater than 10!</p>
        {end}
        {if @count < 0}
          <p class="message warning">⚠️  Count is negative!</p>
        {end}
        <button onclick="{increment}">Increment</button>
        <button onclick="{decrement}">Decrement</button>
      </div>
    }
  end

  def css
    %Q{
      .wrapper {
        background: linear-gradient(45deg, black, #f37b812e);
        color: white;
        padding: 30px;
        border-radius: 8px;
        border: 1px solid #623c3c;
      }
      .message {
        background: rgba(255, 255, 255, 0.1);
        padding: 15px;
        margin: 15px 0;
        border-radius: 6px;
        border-left: 4px solid #4CAF50;
        font-size: 16px;
      }
      .message.success {
        border-left-color: #2196F3;
        background: rgba(33, 150, 243, 0.2);
      }
      .message.warning {
        border-left-color: #FF9800;
        background: rgba(255, 152, 0, 0.2);
      }
      button {
        border: 1px solid #ff92b3;
        padding: 8px 10px;
        border-radius: 8px;
        color: white;
        cursor: pointer;
        background: #a53269;
        margin: 5px;
      }
      button:hover {
        background: #c7588d;
      }
    }
  end

  def box_class
    @count > 0 ? "positive" : "neutral"
  end

  def increment
    @count = @count + 1
  end

  def decrement
    @count = @count - 1
  end

  def mounted
  end

  def unmounted
  end
end
