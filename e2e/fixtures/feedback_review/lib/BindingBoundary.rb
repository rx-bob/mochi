class BindingBoundary
  @tag_name = "binding-boundary"
  prop :seed, Integer, required: true
  prop :rows, Array, required: true
  def initialize
    @rows_visible = true
    @last_event = "none"
    @event_count = 0
  end
  def authored_0; @seed + 0; end
  def authored_1; @seed + 1; end
  def authored_2; @seed + 2; end
  def authored_3; @seed + 3; end
  def authored_4; @seed + 4; end
  def authored_5; @seed + 5; end
  def authored_6; @seed + 6; end
  def authored_7; @seed + 7; end
  def authored_8; @seed + 8; end
  def authored_9; @seed + 9; end
  def authored_10; @seed + 10; end
  def authored_11; @seed + 11; end
  def authored_12; @seed + 12; end
  def authored_13; @seed + 13; end
  def authored_14; @seed + 14; end
  def authored_15; @seed + 15; end
  def authored_16; @seed + 16; end
  def authored_17; @seed + 17; end
  def authored_18; @seed + 18; end
  def authored_19; @seed + 19; end
  def authored_20; @seed + 20; end
  def authored_21; @seed + 21; end
  def authored_22; @seed + 22; end
  def authored_23; @seed + 23; end
  def authored_24; @seed + 24; end
  def authored_25; @seed + 25; end
  def authored_26; @seed + 26; end
  def authored_27; @seed + 27; end
  def authored_28; @seed + 28; end
  def authored_29; @seed + 29; end
  def authored_30; @seed + 30; end
  def authored_31; @seed + 31; end
  def authored_32; @seed + 32; end
  def authored_33; @seed + 33; end
  def authored_34; @seed + 34; end
  def authored_35; @seed + 35; end
  def authored_36; @seed + 36; end
  def authored_37; @seed + 37; end
  def authored_38; @seed + 38; end
  def authored_39; @seed + 39; end
  def authored_40; @seed + 40; end
  def authored_41; @seed + 41; end
  def authored_42; @seed + 42; end
  def authored_43; @seed + 43; end
  def authored_44; @seed + 44; end
  def authored_45; @seed + 45; end
  def authored_46; @seed + 46; end
  def authored_47; @seed + 47; end
  def authored_48; @seed + 48; end
  def authored_49; @seed + 49; end
  def authored_50; @seed + 50; end
  def authored_51; @seed + 51; end
  def authored_52; @seed + 52; end
  def authored_53; @seed + 53; end
  def authored_54; @seed + 54; end
  def authored_55; @seed + 55; end
  def authored_56; @seed + 56; end
  def authored_57; @seed + 57; end
  def authored_58; @seed + 58; end
  def authored_59; @seed + 59; end
  def authored_60; @seed + 60; end
  def authored_61; @seed + 61; end
  def authored_62; @seed + 62; end
  def authored_63; @seed + 63; end
  def authored_64; @seed + 64; end
  def authored_65; @seed + 65; end
  def authored_66; @seed + 66; end
  def authored_67; @seed + 67; end
  def authored_68; @seed + 68; end
  def authored_69; @seed + 69; end
  def authored_70; @seed + 70; end
  def authored_71; @seed + 71; end
  def authored_72; @seed + 72; end
  def authored_73; @seed + 73; end
  def authored_74; @seed + 74; end
  def authored_75; @seed + 75; end
  def authored_76; @seed + 76; end
  def authored_77; @seed + 77; end
  def authored_78; @seed + 78; end
  def authored_79; @seed + 79; end
  def authored_80; @seed + 80; end
  def authored_81; @seed + 81; end
  def authored_82; @seed + 82; end
  def authored_83; @seed + 83; end
  def authored_84; @seed + 84; end
  def authored_85; @seed + 85; end
  def authored_86; @seed + 86; end
  def authored_87; @seed + 87; end
  def authored_88; @seed + 88; end
  def authored_89; @seed + 89; end
  def authored_90; @seed + 90; end
  def authored_91; @seed + 91; end
  def authored_92; @seed + 92; end
  def authored_93; @seed + 93; end
  def authored_94; @seed + 94; end
  def authored_95; @seed + 95; end
  def authored_96; @seed + 96; end
  def authored_97; @seed + 97; end
  def authored_98; @seed + 98; end
  def authored_99; @seed + 99; end
  def authored_100; @seed + 100; end
  def authored_101; @seed + 101; end
  def authored_102; @seed + 102; end
  def authored_103; @seed + 103; end
  def authored_104; @seed + 104; end
  def authored_105; @seed + 105; end
  def authored_106; @seed + 106; end
  def authored_107; @seed + 107; end
  def authored_108; @seed + 108; end
  def authored_109; @seed + 109; end
  def authored_110; @seed + 110; end
  def authored_111; @seed + 111; end
  def authored_112; @seed + 112; end
  def authored_113; @seed + 113; end
  def toggle_rows
    @rows_visible = !@rows_visible
  end
  def row_action(event)
    @last_event = event["value"]
    @event_count = @event_count + 1
  end
  def html
    %Q{
      <section class="binding-boundary">
        <output class="seed">{@seed}</output>
        <span class="binding-value" data-slot="0">{@seed + 0}</span>
        <span class="binding-value" data-slot="1">{@seed + 1}</span>
        <span class="binding-value" data-slot="2">{@seed + 2}</span>
        <span class="binding-value" data-slot="3">{@seed + 3}</span>
        <span class="binding-value" data-slot="4">{@seed + 4}</span>
        <span class="binding-value" data-slot="5">{@seed + 5}</span>
        <span class="binding-value" data-slot="6">{@seed + 6}</span>
        <span class="binding-value" data-slot="7">{@seed + 7}</span>
        <span class="binding-value" data-slot="8">{@seed + 8}</span>
        <span class="binding-value" data-slot="9">{@seed + 9}</span>
        <span class="binding-value" data-slot="10">{@seed + 10}</span>
        <span class="binding-value" data-slot="11">{@seed + 11}</span>
        <span class="binding-value" data-slot="12">{@seed + 12}</span>
        <span class="binding-value" data-slot="13">{@seed + 13}</span>
        <span class="binding-value" data-slot="14">{@seed + 14}</span>
        <span class="binding-value" data-slot="15">{@seed + 15}</span>
        <span class="binding-value" data-slot="16">{@seed + 16}</span>
        <span class="binding-value" data-slot="17">{@seed + 17}</span>
        <span class="binding-value" data-slot="18">{@seed + 18}</span>
        <span class="binding-value" data-slot="19">{@seed + 19}</span>
        <span class="binding-value" data-slot="20">{@seed + 20}</span>
        <span class="binding-value" data-slot="21">{@seed + 21}</span>
        <span class="binding-value" data-slot="22">{@seed + 22}</span>
        <span class="binding-value" data-slot="23">{@seed + 23}</span>
        <span class="binding-value" data-slot="24">{@seed + 24}</span>
        <span class="binding-value" data-slot="25">{@seed + 25}</span>
        <span class="binding-value" data-slot="26">{@seed + 26}</span>
        <span class="binding-value" data-slot="27">{@seed + 27}</span>
        <span class="binding-value" data-slot="28">{@seed + 28}</span>
        <span class="binding-value" data-slot="29">{@seed + 29}</span>
        <span class="binding-value" data-slot="30">{@seed + 30}</span>
        <span class="binding-value" data-slot="31">{@seed + 31}</span>
        <span class="binding-value" data-slot="32">{@seed + 32}</span>
        <span class="binding-value" data-slot="33">{@seed + 33}</span>
        <span class="binding-value" data-slot="34">{@seed + 34}</span>
        <span class="binding-value" data-slot="35">{@seed + 35}</span>
        <span class="binding-value" data-slot="36">{@seed + 36}</span>
        <span class="binding-value" data-slot="37">{@seed + 37}</span>
        <span class="binding-value" data-slot="38">{@seed + 38}</span>
        <span class="binding-value" data-slot="39">{@seed + 39}</span>
        <span class="binding-value" data-slot="40">{@seed + 40}</span>
        <span class="binding-value" data-slot="41">{@seed + 41}</span>
        <span class="binding-value" data-slot="42">{@seed + 42}</span>
        <span class="binding-value" data-slot="43">{@seed + 43}</span>
        <span class="binding-value" data-slot="44">{@seed + 44}</span>
        <span class="binding-value" data-slot="45">{@seed + 45}</span>
        <span class="binding-value" data-slot="46">{@seed + 46}</span>
        <span class="binding-value" data-slot="47">{@seed + 47}</span>
        <span class="binding-value" data-slot="48">{@seed + 48}</span>
        <span class="binding-value" data-slot="49">{@seed + 49}</span>
        <span class="binding-value" data-slot="50">{@seed + 50}</span>
        <span class="binding-value" data-slot="51">{@seed + 51}</span>
        <span class="binding-value" data-slot="52">{@seed + 52}</span>
        <span class="binding-value" data-slot="53">{@seed + 53}</span>
        <span class="binding-value" data-slot="54">{@seed + 54}</span>
        <span class="binding-value" data-slot="55">{@seed + 55}</span>
        <span class="binding-value" data-slot="56">{@seed + 56}</span>
        <span class="binding-value" data-slot="57">{@seed + 57}</span>
        <span class="binding-value" data-slot="58">{@seed + 58}</span>
        <span class="binding-value" data-slot="59">{@seed + 59}</span>
        <span class="binding-value" data-slot="60">{@seed + 60}</span>
        <span class="binding-value" data-slot="61">{@seed + 61}</span>
        <span class="binding-value" data-slot="62">{@seed + 62}</span>
        <span class="binding-value" data-slot="63">{@seed + 63}</span>
        <span class="binding-value" data-slot="64">{@seed + 64}</span>
        <span class="binding-value" data-slot="65">{@seed + 65}</span>
        <span class="binding-value" data-slot="66">{@seed + 66}</span>
        <span class="binding-value" data-slot="67">{@seed + 67}</span>
        <span class="binding-value" data-slot="68">{@seed + 68}</span>
        <span class="binding-value" data-slot="69">{@seed + 69}</span>
        <span class="binding-value" data-slot="70">{@seed + 70}</span>
        <span class="binding-value" data-slot="71">{@seed + 71}</span>
        <span class="binding-value" data-slot="72">{@seed + 72}</span>
        <span class="binding-value" data-slot="73">{@seed + 73}</span>
        <span class="binding-value" data-slot="74">{@seed + 74}</span>
        <span class="binding-value" data-slot="75">{@seed + 75}</span>
        <span class="binding-value" data-slot="76">{@seed + 76}</span>
        <span class="binding-value" data-slot="77">{@seed + 77}</span>
        <span class="binding-value" data-slot="78">{@seed + 78}</span>
        <span class="binding-value" data-slot="79">{@seed + 79}</span>
        <span class="binding-value" data-slot="80">{@seed + 80}</span>
        <span class="binding-value" data-slot="81">{@seed + 81}</span>
        <span class="binding-value" data-slot="82">{@seed + 82}</span>
        <span class="binding-value" data-slot="83">{@seed + 83}</span>
        <span class="binding-value" data-slot="84">{@seed + 84}</span>
        <span class="binding-value" data-slot="85">{@seed + 85}</span>
        <span class="binding-value" data-slot="86">{@seed + 86}</span>
        <span class="binding-value" data-slot="87">{@seed + 87}</span>
        <span class="binding-value" data-slot="88">{@seed + 88}</span>
        <span class="binding-value" data-slot="89">{@seed + 89}</span>
        <span class="binding-value" data-slot="90">{@seed + 90}</span>
        <span class="binding-value" data-slot="91">{@seed + 91}</span>
        <span class="binding-value" data-slot="92">{@seed + 92}</span>
        <span class="binding-value" data-slot="93">{@seed + 93}</span>
        <span class="binding-value" data-slot="94">{@seed + 94}</span>
        <span class="binding-value" data-slot="95">{@seed + 95}</span>
        <span class="binding-value" data-slot="96">{@seed + 96}</span>
        <span class="binding-value" data-slot="97">{@seed + 97}</span>
        <span class="binding-value" data-slot="98">{@seed + 98}</span>
        <span class="binding-value" data-slot="99">{@seed + 99}</span>
        <span class="binding-value" data-slot="100">{@seed + 100}</span>
        <span class="binding-value" data-slot="101">{@seed + 101}</span>
        <span class="binding-value" data-slot="102">{@seed + 102}</span>
        <span class="binding-value" data-slot="103">{@seed + 103}</span>
        <span class="binding-value" data-slot="104">{@seed + 104}</span>
        <span class="binding-value" data-slot="105">{@seed + 105}</span>
        <span class="binding-value" data-slot="106">{@seed + 106}</span>
        <span class="binding-value" data-slot="107">{@seed + 107}</span>
        <span class="binding-value" data-slot="108">{@seed + 108}</span>
        <span class="binding-value" data-slot="109">{@seed + 109}</span>
        <span class="binding-value" data-slot="110">{@seed + 110}</span>
        <span class="binding-value" data-slot="111">{@seed + 111}</span>
        <span class="binding-value" data-slot="112">{@seed + 112}</span>
        <span class="binding-value" data-slot="113">{@seed + 113}</span>
        <span class="binding-value" data-slot="114">{@seed + 114}</span>
        <span class="binding-value" data-slot="115">{@seed + 115}</span>
        <span class="binding-value" data-slot="116">{@seed + 116}</span>
        <span class="binding-value" data-slot="117">{@seed + 117}</span>
        <span class="binding-value" data-slot="118">{@seed + 118}</span>
        <span class="binding-value" data-slot="119">{@seed + 119}</span>
        <span class="binding-value" data-slot="120">{@seed + 120}</span>
        <span class="binding-value" data-slot="121">{@seed + 121}</span>
        <span class="binding-value" data-slot="122">{@seed + 122}</span>
        <span class="binding-value" data-slot="123">{@seed + 123}</span>
        <span class="binding-value" data-slot="124">{@seed + 124}</span>
        <span class="binding-value" data-slot="125">{@seed + 125}</span>
        <span class="binding-value" data-slot="126">{@seed + 126}</span>
        <span class="binding-value" data-slot="127">{@seed + 127}</span>
        <span class="binding-value" data-slot="128">{@seed + 128}</span>
        <span class="binding-value" data-slot="129">{@seed + 129}</span>
        <span class="binding-value" data-slot="130">{@seed + 130}</span>
        <span class="binding-value" data-slot="131">{@seed + 131}</span>
        <span class="binding-value" data-slot="132">{@seed + 132}</span>
        <span class="binding-value" data-slot="133">{@seed + 133}</span>
        <span class="binding-value" data-slot="134">{@seed + 134}</span>
        <span class="binding-value" data-slot="135">{@seed + 135}</span>
        <span class="binding-value" data-slot="136">{@seed + 136}</span>
        <span class="binding-value" data-slot="137">{@seed + 137}</span>
        <span class="binding-value" data-slot="138">{@seed + 138}</span>
        <span class="binding-value" data-slot="139">{@seed + 139}</span>
        <button class="toggle-rows" onclick="{toggle_rows}">Toggle rows</button>
        <output class="last-event">{@last_event}</output>
        <output class="event-count">{@event_count}</output>
        {if @rows_visible}
          {each @rows as row, key: row["id"]}
            <div class="boundary-row" data-row="{row["id"]}">
              <span class="row-label">{row["label"]}</span>
              <review-child label="{row["label"]}" meta="{row["meta"]}" on:action="{row_action($event)}" on:change="{row_action($event)}"></review-child>
            </div>
          {end}
        {end}
      </section>
    }
  end
end

