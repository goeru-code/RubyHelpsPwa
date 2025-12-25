require 'json'

# --- 1. DATA EXTRACTION (The State Machine) ---
target_file = Dir.glob("*.def").first
unless target_file; puts "No .def found"; exit; end

raw_content = File.read(target_file, mode: 'rb', encoding: 'UTF-8')
schema = raw_content =~ /begin schema\s+name\s+:\s+(.*?)\n/ ? $1.strip : "NASA_PWA_V12"

vuis = []
raw_content.scan(/^vui\s+\{.*?id\s+:\s+(\d+).*?name\s+:\s+(.*?)\n/m).each do |id, name|
  vuis << { id: id.strip, name: name.strip }
end
vuis.uniq! { |v| v[:id] }

fields = []
raw_content.split(/^field\s+\{/).each_with_index do |block, i|
  next if i == 0 
  f = { id: nil, name: nil, type: nil, vuis: [], vui_parents: {} }
  f[:id]   = $1 if block =~ /^\s+id\s+:\s+(\d+)/
  f[:name] = $1 if block =~ /^\s+name\s+:\s+(.*?)\n/
  f[:type] = $1.to_i if block =~ /^\s+datatype\s+:\s+(\d+)/
  
  # State Machine for "Inhaling" lines
  current_vector = ""
  
  block.each_line do |line|
    if line =~ /^\s+display-instance\s+:\s+(.*)$/
      content = $1
      has_continuation = content.include?("&")
      
      # Clean the content (remove trailing &)
      clean_content = content.gsub(/&\s*$/, "").strip
      current_vector += clean_content
      
      # If no ampersand, the vector is complete for this VUI
      unless has_continuation
        if current_vector =~ /^(\d+)\\/
          v_id = $1
          f[:vuis] << v_id unless f[:vuis].include?(v_id)
          
          # Now search for Property 170 (Parent) in the fully inhaled vector
          if current_vector =~ /\\170\\(?:40|2|4|6|0|21)\\(\d+)/
            parent_id = $1
            unless ["0", "4294967295"].include?(parent_id)
              f[:vui_parents][v_id] = parent_id
            end
          end
        end
        current_vector = "" # Reset for next vector
      end
    end
  end
  fields << f if f[:id]
end

# --- 2. RENDERER (CSS & Search Intact) ---
def generate_view(schema, vuis, fields, mode)
  html = <<~HTML
    <!DOCTYPE html>
    <html><head><style>
      body { background: #0c0c0c; color: #ccc; font-family: 'Segoe UI', sans-serif; margin: 0; display: flex; }
      #sidebar { width: 200px; background: #111; height: 100vh; position: fixed; padding: 20px; border-right: 1px solid #333; z-index:100; }
      #content { margin-left: 200px; padding: 20px; width: calc(100% - 200px); }
      .nav-btn { display: block; padding: 10px; margin-bottom: 5px; background: #222; color: #888; text-decoration: none; text-align: center; border-radius: 4px; font-size: 11px; }
      .active { background: #0078d4 !important; color: white !important; }
      .vui-container { background: #161616; border: 1px solid #333; margin-bottom: 30px; border-radius: 8px; padding: 15px; }
      .vui-title { color: #00a2ed; font-weight: bold; margin-bottom: 15px; border-bottom: 1px solid #333; padding-bottom: 10px; margin-left: 15px; font-size: 1.2em; }
      .root-grid { display: flex; flex-wrap: wrap; gap: 20px; align-items: flex-start; }
      .node-group { display: flex; flex-direction: column; }
      .box { width: 150px; min-height: 65px; background: #222; border: 1px solid #444; padding: 8px; font-size: 10px; text-align: center; cursor: pointer; border-radius: 4px; box-sizing: border-box; }
      .box b { display: block; margin-bottom: 5px; color: #fff; }
      .f-id { font-size: 13px; font-weight: bold; color: #aaa; }
      .panel { border-top: 4px solid #00a2ed; background: #1a242f; }
      .holder { border-top: 4px solid #d4af37; background: #28261e; }
      .child-area { margin-left: 20px; border-left: 1px dashed #555; padding-left: 10px; margin-top: 5px; }
      .child-item { display: flex; flex-direction: column; margin-top: 8px; }
      #search { width: 100%; padding: 8px; background: #000; border: 1px solid #444; color: #fff; margin-bottom: 20px; }
      .hidden { display: none !important; }
    </style></head>
    <body>
      <div id="sidebar">
        <h4 style="margin:0 0 10px 0; color:#0078d4;">NASA V12</h4>
        <input type="text" id="search" placeholder="Quick Search..." onkeyup="doSearch()">
        <a href="flat.html" class="nav-btn #{mode == :flat ? 'active' : ''}">FLAT</a>
        <a href="hierarchy.html" class="nav-btn #{mode == :hierarchy ? 'active' : ''}">HIERARCHY</a>
      </div>
      <div id="content">
  HTML

  vuis.each do |v|
    v_id = v[:id]
    v_fields = fields.select { |f| f[:vuis].include?(v_id) }
    html += "<div class='vui-container'><div class='vui-title'>VIEW: #{v[:name]} (#{v_fields.size} Fields)</div>"
    
    rendered_ids = []
    draw_chain = ->(p_id) {
      kids = v_fields.select { |f| f[:vui_parents][v_id] == p_id }
      return "" if kids.empty?
      res = "<div class='child-area'>"
      kids.each do |k|
        rendered_ids << k[:id]
        cls = k[:type] == 35 ? "panel" : (k[:type] == 36 ? "holder" : "")
        res += "<div class='child-item'>"
        res += "<div class='box #{cls}' onclick='copyId(\"#{k[:id]}\")'><b>#{k[:name]}</b><span class='f-id'>#{k[:id]}</span></div>"
        res += draw_chain.call(k[:id])
        res += "</div>"
      end
      res += "</div>"
      res
    }

    html += "<div class='root-grid'>"
    if mode == :hierarchy
      v_ids = v_fields.map{|f| f[:id]}
      roots = v_fields.select { |f| f[:vui_parents][v_id].nil? || !v_ids.include?(f[:vui_parents][v_id]) }
      roots.each do |r|
        rendered_ids << r[:id]
        cls = r[:type] == 35 ? "panel" : (r[:type] == 36 ? "holder" : "")
        html += "<div class='node-group'><div class='box #{cls}' onclick='copyId(\"#{r[:id]}\")'><b>#{r[:name]}</b><span class='f-id'>#{r[:id]}</span></div>"
        html += draw_chain.call(r[:id])
        html += "</div>"
      end
      v_fields.each { |f| unless rendered_ids.include?(f[:id])
          html += "<div class='node-group'><div class='box' style='border-color:#500;' onclick='copyId(\"#{f[:id]}\")'><b>#{f[:name]}</b><span class='f-id'>#{f[:id]}</span></div></div>"
      end }
    else
      v_fields.each { |f|
        cls = f[:type] == 35 ? "panel" : (f[:type] == 36 ? "holder" : "")
        html += "<div class='box #{cls}' onclick='copyId(\"#{f[:id]}\")'><b>#{f[:name]}</b><span class='f-id'>#{f[:id]}</span></div>"
      }
    end
    html += "</div></div>"
  end

  html += "</div><script>
    function doSearch(){
      let val = document.getElementById('search').value.toLowerCase();
      document.querySelectorAll('.box').forEach(b => {
        let isMatch = b.innerText.toLowerCase().includes(val);
        b.classList.toggle('hidden', !isMatch);
        let pg = b.closest('.node-group');
        if(pg) pg.classList.toggle('hidden', !isMatch);
      });
    }
    function copyId(id){ navigator.clipboard.writeText(id); }
  </script></body></html>"
  html
end

File.write("flat.html", generate_view(schema, vuis, fields, :flat))
File.write("hierarchy.html", generate_view(schema, vuis, fields, :hierarchy))
system("start flat.html")
