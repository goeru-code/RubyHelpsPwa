require 'json'
require 'fileutils'

# --- 1. CONFIG & SAFETY CHECK ---
# We look for any .def file in the current directory
target_file = Dir.glob("*.def").first

if target_file.nil?
  puts "!!! ERROR: No .def file found in: #{Dir.pwd}"
  puts "Please ensure this script is in the same folder as your .def file."
  exit
end

vuis = []
global_schema = "UNKNOWN_SCHEMA"

# --- 2. DATA EXTRACTION ---
# Parsing the file to build the UI
begin
  File.open(target_file, "r:UTF-8") do |f|
    f.each_line do |line|
      break if line =~ /^field\s+\{/ 
      if line =~ /^\s*name\s*:\s*(.*)$/ && global_schema == "UNKNOWN_SCHEMA"
         global_schema = $1.strip
      end
      if line =~ /^vui\s+\{/
        id, name = nil, nil
        while (vui_line = f.gets)
          id = $1.strip if vui_line =~ /^\s+id\s+:\s+(\d+)/
          name = $1.strip if vui_line =~ /^\s+name\s+:\s+(.*?)$/
          break if vui_line =~ /^\}/
        end
        vuis << { id: id, name: name } if id
      end
    end
  end
rescue => e
  puts "Error reading file: #{e.message}"
  exit
end

vui_map = Hash.new { |h, k| h[k] = [] }
current_field = nil
current_vector = ""

File.open(target_file, "r:UTF-8") do |f|
  f.each_line do |line|
    if line =~ /^field\s+\{/
      current_field = { id: nil, name: "Loading...", type: 0, parents: {} }
    elsif current_field && line =~ /^\s+id\s+:\s+(\d+)/
      current_field[:id] = $1
    elsif current_field && line =~ /^\s+name\s+:\s+(.*?)$/
      current_field[:name] = $1.strip
    elsif current_field && line =~ /^\s+datatype\s+:\s+(\d+)/
      current_field[:type] = $1.to_i
    elsif current_field && line =~ /^\s+display-instance\s+:\s+(.*)$/
      content = $1
      has_cont = content.include?("&")
      current_vector += content.gsub(/&\s*$/, "").strip
      unless has_cont
        if current_vector =~ /^(\d+)\\/
          v_id = $1
          if current_vector =~ /\\170\\(?:40|2|4|6|0|21)\\(\d+)/
            current_field[:parents][v_id] = $1 unless ["0", "4294967295"].include?($1)
          end
          vui_map[v_id] << current_field.dup
        end
        current_vector = ""
      end
    elsif line =~ /^\}/
      current_field = nil
    end
  end
end

# --- 3. RENDERER ---
html = <<~HTML
<!DOCTYPE html>
<html><head>
  <title>RubyHelpsPwa</title>
  <style>
  html, body { height: 100%; margin: 0; background: #0c0c0c; color: #ccc; font-family: 'Segoe UI', sans-serif; overflow: hidden; }
  .wrapper { display: flex; height: 100vh; width: 100vw; }

  #sidebar { width: 220px; min-width: 220px; background: #111; border-right: 1px solid #333; padding: 20px; box-sizing: border-box; display: flex; flex-direction: column; }
  #content { flex-grow: 1; overflow-y: auto; padding: 0 40px 40px 40px; box-sizing: border-box; }
  
  #header-block { position: sticky; top: 0; background: #0c0c0c; padding: 20px 0; z-index: 50; border-bottom: 1px solid #333; margin-bottom: 20px; }
  #schema-title { font-size: 18px; font-weight: 800; color: #fff; margin-bottom: 10px; }
  #breadcrumb { background: #1a1a1a; padding: 12px 15px; border-radius: 4px; border: 1px solid #333; font-size: 11px; color: #00a2ed; min-height: 18px; }

  .nav-btn { display: block; padding: 10px; margin-bottom: 5px; background: #222; color: #888; text-decoration: none; text-align: center; border-radius: 4px; font-size: 11px; cursor: pointer; border: 1px solid transparent; transition: 0.2s; }
  .nav-btn:hover { background: #333; color: #fff; }
  .active { background: #0078d4 !important; color: white !important; }
  
  .action-btn { background: #333; color: #fff; margin-top: 10px; border: 1px solid #444; }
  .action-btn:disabled { opacity: 0.2; cursor: not-allowed; }
  #btn-save { background: #28a745 !important; color: white !important; margin-top: 20px; font-weight: bold; display: none; }

  .vui-container { background: #161616; border: 1px solid #333; margin-bottom: 25px; border-radius: 8px; }
  summary { padding: 15px; cursor: pointer; background: #1c1c1c; font-weight: bold; color: #00a2ed; outline: none; border-radius: 8px 8px 0 0; }
  
  .root-grid { padding: 30px 30px 30px 45px; display: flex; flex-wrap: wrap; gap: 20px; align-items: flex-start; }
  
  .box { 
    width: 155px !important; min-width: 155px !important; max-width: 155px !important;
    min-height: 57px; background: #666; border: 2px solid transparent; padding: 6px 8px; 
    font-size: 10px; text-align: center; cursor: pointer; border-radius: 4px; box-sizing: border-box; 
    color: #fff; box-shadow: 0 2px 4px rgba(0,0,0,0.3); 
  }
  .box.selected { border: 2px solid #00a2ed; background: #444; }
  .box b { display: block; margin-bottom: 3px; color: #fff; font-weight: 800; text-shadow: 1px 1px 2px #000; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
  .f-id { font-size: 13px; font-weight: bold; color: #fff; }
  
  .panel { border-top: 4px solid #00a2ed; background: #1a242f; border-color: #334; }
  .holder { border-top: 4px solid #d4af37; background: #28261e; border-color: #443; }
  
  .child-area { margin-left: 20px; border-left: 1px dashed #555; padding-left: 15px; margin-top: 8px; display: flex; flex-direction: column; }
  .child-item { display: flex; flex-direction: column; margin-top: 10px; }

  body.flat-mode .root-grid { display: grid; grid-template-columns: repeat(auto-fill, 155px); gap: 15px; padding: 30px 30px 30px 45px; }
  body.flat-mode .child-area, body.flat-mode .child-item, body.flat-mode .node-group { display: contents; }

  #clip-info { font-size: 10px; color: #888; margin-top: auto; padding: 10px; border-top: 1px solid #333; }
</style></head>
<body>
  <div class="wrapper">
    <div id="sidebar">
      <h4 style="margin:0 0 10px 0; color:#0078d4;">RubyHelpsPwa</h4>
      <div id="btn-flat" class="nav-btn" onclick="setView('flat')">FLAT VIEW</div>
      <div id="btn-hier" class="nav-btn active" onclick="setView('hier')">HIERARCHY VIEW</div>
      
      <hr style="width:100%; border:0; border-top:1px solid #333; margin:15px 0;">
      
      <button id="btn-copy" class="nav-btn action-btn" onclick="doCopy()" disabled>COPY FIELD</button>
      <button id="btn-paste" class="nav-btn action-btn" onclick="doPaste()" disabled>PASTE INTO</button>
      
      <button id="btn-save" class="nav-btn" onclick="doSave()">SAVE TO .DEF</button>
      
      <div id="clip-info">Clipboard: Empty</div>
    </div>
    <div id="content">
      <div id="header-block">
        <div id="schema-title">Schema: #{global_schema}</div>
        <div id="breadcrumb">Select a field to begin...</div>
      </div>
HTML

vuis.each do |v|
  v_id = v[:id]
  v_fields = vui_map[v_id] || []
  vui_root_path = "#{global_schema} > #{v[:name]}"
  
  html += "<details id='vui_#{v_id}'><summary>VIEW: #{v[:name]} (#{v_fields.size} Fields)</summary><div class='vui-container'><div class='root-grid'>"
  
  draw_chain = ->(p_id, path_names) {
    kids = v_fields.select { |f| f[:parents][v_id] == p_id }
    return "" if kids.empty?
    res = "<div class='child-area'>"
    kids.each do |k|
      cls = k[:type] == 35 ? "panel" : (k[:type] == 36 ? "holder" : "")
      current_path = path_names + [k[:name]]
      res += "<div class='child-item'>"
      res += "<div class='box #{cls}' id='box_#{v_id}_#{k[:id]}' onclick='selectField(\"#{v_id}\", \"#{k[:id]}\", \"#{k[:name]}\", #{k[:type]}, \"#{current_path.join(' > ')}\")'><b>#{k[:name]}</b><span class='f-id'>#{k[:id]}</span></div>"
      res += draw_chain.call(k[:id], current_path)
      res += "</div>"
    end
    res += "</div>"
    res
  }

  roots = v_fields.select { |f| f[:parents][v_id].nil? || !v_fields.any?{|p| p[:id] == f[:parents][v_id]} }
  roots.each do |r|
    cls = r[:type] == 35 ? "panel" : (r[:type] == 36 ? "holder" : "")
    current_path = [vui_root_path, r[:name]]
    html += "<div class='node-group'><div class='box #{cls}' id='box_#{v_id}_#{r[:id]}' onclick='selectField(\"#{v_id}\", \"#{r[:id]}\", \"#{r[:name]}\", #{r[:type]}, \"#{current_path.join(' > ')}\")'><b>#{r[:name]}</b><span class='f-id'>#{r[:id]}</span></div>"
    html += draw_chain.call(r[:id], current_path)
    html += "</div>"
  end
  html += "</div></div></details>"
end

html += "</div></div><script>
  let selectedId = null;
  let selectedVui = null;
  let selectedType = null;
  let clipboardId = null;
  let pendingChanges = [];

  function setView(mode) {
    if(mode === 'flat') {
      document.body.classList.add('flat-mode');
      document.getElementById('btn-flat').classList.add('active');
      document.getElementById('btn-hier').classList.remove('active');
    } else {
      document.body.classList.remove('flat-mode');
      document.getElementById('btn-hier').classList.add('active');
      document.getElementById('btn-flat').classList.remove('active');
    }
  }

  function selectField(vui, id, name, type, path) {
    if(selectedId && selectedVui) {
      const old = document.getElementById('box_' + selectedVui + '_' + selectedId);
      if(old) old.classList.remove('selected');
    }
    selectedId = id;
    selectedVui = vui;
    selectedType = type;
    document.getElementById('box_' + vui + '_' + id).classList.add('selected');
    document.getElementById('breadcrumb').innerHTML = '<strong>Path:</strong> ' + path + ' (ID: ' + id + ')';
    
    document.getElementById('btn-copy').disabled = (type === 35 || type === 36);
    document.getElementById('btn-paste').disabled = !(clipboardId && (type === 35 || type === 36));
  }

  function doCopy() {
    clipboardId = selectedId;
    document.getElementById('clip-info').innerHTML = 'Clipboard: ' + clipboardId;
    if(selectedType === 35 || selectedType === 36) document.getElementById('btn-paste').disabled = false;
  }

  function doPaste() {
    if(!clipboardId) return;
    if(confirm('Confirm: Copy Field ' + clipboardId + ' into ' + selectedId + '?')) {
      pendingChanges.push({vui: selectedVui, field: clipboardId, parent: selectedId});
      document.getElementById('btn-save').style.display = 'block';
    }
  }

  function doSave() {
    if(confirm('This will create a backup and update the .def file. Proceed?')) {
      // In the real version, we'll send 'pendingChanges' back to a Ruby listener.
      console.log('Final Payload:', pendingChanges);
      alert('Save instruction recorded. Implementation of file-writer starts tomorrow!');
    }
  }
</script></body></html>"

File.write("nasa_visualizer.html", html)
system("start nasa_visualizer.html")
