require 'json'
require 'fileutils'
require 'webrick'

# --- 1. CONFIG ---
TARGET_FILE = Dir.glob("*.def").first
if TARGET_FILE.nil?
  puts "!!! ERROR: No .def file found in: #{Dir.pwd}"
  exit
end

# --- 2. DATA EXTRACTION ---
def get_latest_data
  vuis = []
  global_schema = "UNKNOWN_SCHEMA"
  vui_map = Hash.new { |h, k| h[k] = [] }
  
  File.open(TARGET_FILE, "r:UTF-8") do |f|
    f.each_line do |line|
      break if line =~ /^field\s+\{/ 
      global_schema = $1.strip if line =~ /^\s*name\s*:\s*(.*)$/ && global_schema == "UNKNOWN_SCHEMA"
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

  current_field = nil
  current_vector = ""
  File.open(TARGET_FILE, "r:UTF-8") do |f|
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
        current_vector += content.gsub(/&\s*$/, "").strip
        unless content.include?("&")
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
  [global_schema, vuis, vui_map]
end

# --- 3. FILE WRITER ---
def apply_changes(changes)
  backup = "#{TARGET_FILE}.#{Time.now.strftime('%H%M%S')}.bak"
  FileUtils.cp(TARGET_FILE, backup)
  
  lines = File.readlines(TARGET_FILE, encoding: "UTF-8")
  changes.each do |change|
    f_id = change["field"]; p_id = change["parent"]; v_id = change["vui"]
    new_line = "    display-instance : \"#{v_id}\\\\170\\\\40\\\\#{p_id}\"\n"
    
    inside = false
    lines.each_with_index do |line, idx|
      if line =~ /^field\s+\{/
        j = idx + 1
        while lines[j] && lines[j] !~ /^(field|vui)\s+\{/
          (inside = true; break) if lines[j] =~ /^\s+id\s+:\s+#{f_id}\b/
          j += 1
        end
      end
      if inside && line =~ /^\}/
        lines.insert(idx, new_line)
        inside = false; break
      end
    end
  end
  File.write(TARGET_FILE, lines.join)
  backup
end

# --- 4. HTML RENDERER ---
def generate_html(schema, vuis, vui_map)
  vui_content = vuis.map do |v|
    v_fields = vui_map[v[:id]] || []
    draw_node = ->(parent_id) {
      kids = v_fields.select { |f| f[:parents][v[:id]] == parent_id }
      return "" if kids.empty?
      "<div class='child-area'>" + kids.map { |k|
        cls = k[:type] == 35 ? "panel" : (k[:type] == 36 ? "holder" : "")
        "<div class='child-item'><div class='box #{cls}' id='box_#{v[:id]}_#{k[:id]}' onclick='selectF(\"#{v[:id]}\",\"#{k[:id]}\",#{k[:type]})'><b>#{k[:name]}</b><br>#{k[:id]}</div>#{draw_node.call(k[:id])}</div>"
      }.join + "</div>"
    }
    roots = v_fields.select { |f| f[:parents][v[:id]].nil? || !v_fields.any?{|p| p[:id] == f[:parents][v[:id]]} }
    root_html = roots.map { |r|
      cls = r[:type] == 35 ? "panel" : (r[:type] == 36 ? "holder" : "")
      "<div class='node-group'><div class='box #{cls}' id='box_#{v[:id]}_#{r[:id]}' onclick='selectF(\"#{v[:id]}\",\"#{r[:id]}\",#{r[:type]})'><b>#{r[:name]}</b><br>#{r[:id]}</div>#{draw_node.call(r[:id])}</div>"
    }.join
    "<details><summary>VIEW: #{v[:name]}</summary><div class='vui-container'><div class='root-grid'>#{root_html}</div></div></details>"
  end.join

  <<~HTML
    <!DOCTYPE html>
    <html><head><title>RubyHelpsPwa</title>
    <style>
      html, body { height: 100%; margin: 0; background: #0c0c0c; color: #ccc; font-family: 'Segoe UI', sans-serif; overflow: hidden; }
      .wrapper { display: flex; height: 100vh; width: 100vw; }
      #sidebar { width: 220px; background: #111; border-right: 1px solid #333; padding: 20px; display: flex; flex-direction: column; }
      #content { flex-grow: 1; overflow-y: auto; padding: 0 40px; }
      .nav-btn { display: block; padding: 10px; margin-bottom: 5px; background: #222; color: #888; text-align: center; border-radius: 4px; font-size: 11px; cursor: pointer; border: 1px solid transparent; }
      .action-btn { background: #333; color: #fff; margin-top: 10px; border: 1px solid #444; }
      .action-btn:disabled { opacity: 0.2; cursor: not-allowed; }
      #btn-save { background: #28a745 !important; color: white !important; display: none; margin-top: 20px; }
      .vui-container { background: #161616; border: 1px solid #333; margin-bottom: 20px; border-radius: 8px; }
      summary { padding: 15px; cursor: pointer; background: #1c1c1c; color: #00a2ed; font-weight: bold; border-radius: 8px; }
      .root-grid { padding: 20px; display: flex; flex-wrap: wrap; gap: 15px; }
      .box { width: 150px; min-height: 50px; background: #444; border: 2px solid transparent; padding: 8px; font-size: 10px; text-align: center; cursor: pointer; border-radius: 4px; }
      .box.selected { border-color: #00a2ed; background: #555; }
      .panel { border-top: 4px solid #00a2ed; }
      .holder { border-top: 4px solid #d4af37; }
      .child-area { margin-left: 20px; border-left: 1px dashed #444; padding-left: 10px; }
      .staged-item { border: 2px dashed #28a745 !important; }
    </style></head>
    <body>
      <div class="wrapper">
        <div id="sidebar">
          <h3 style="color:#00a2ed; margin:0 0 20px 0;">RubyHelpsPwa</h3>
          <div class="nav-btn" onclick="location.reload()">REFRESH FILE</div>
          <button id="btn-copy" class="nav-btn action-btn" onclick="doCopy()" disabled>COPY</button>
          <button id="btn-paste" class="nav-btn action-btn" onclick="doPaste()" disabled>PASTE</button>
          <button id="btn-save" class="nav-btn" onclick="doSave()">SAVE TO .DEF</button>
          <div id="clip-box" style="margin-top:auto; font-size:10px; color:#666;">Clip: Empty</div>
        </div>
        <div id="content">
          <h2 style="color:#fff;">Schema: #{schema}</h2>
          #{vui_content}
        </div>
      </div>
      <script>
        let sId, sVui, sType, cId, cHTML, changes = [];
        function selectF(v, id, t) {
          if(sId) document.getElementById('box_'+sVui+'_'+sId)?.classList.remove('selected');
          sId=id; sVui=v; sType=t;
          document.getElementById('box_'+v+'_'+id).classList.add('selected');
          document.getElementById('btn-copy').disabled = (t==35||t==36);
          document.getElementById('btn-paste').disabled = !(cId && (t==35||t==36));
        }
        function doCopy() {
          cId=sId; cHTML=document.getElementById('box_'+sVui+'_'+sId).innerHTML;
          document.getElementById('clip-box').innerText='Clip: '+cId;
        }
        function doPaste() {
          const b = document.getElementById('box_'+sVui+'_'+sId);
          const a = b.parentElement.querySelector('.child-area') || b.parentElement.appendChild(Object.assign(document.createElement('div'),{className:'child-area'}));
          a.innerHTML += '<div class="child-item"><div class="box staged-item">'+cHTML+'</div></div>';
          changes.push({vui:sVui, field:cId, parent:sId});
          document.getElementById('btn-save').style.display='block';
        }
        async function doSave() {
          if(!confirm('Save '+changes.length+' changes?')) return;
          const r = await fetch('/save', {method:'POST', body:JSON.stringify(changes)});
          const d = await r.json();
          alert('Saved! Backup: '+d.backup);
          location.reload();
        }
      </script>
    </body></html>
  HTML
end

# --- 5. THE SERVLET ---
class PwaServlet < WEBrick::HTTPServlet::AbstractServlet
  def do_GET(req, res)
    schema, vuis, vui_map = get_latest_data
    res.status = 200
    res['Content-Type'] = 'text/html'
    res.body = generate_html(schema, vuis, vui_map)
  end
  def do_POST(req, res)
    if req.path == '/save'
      backup_path = apply_changes(JSON.parse(req.body))
      res.status = 200
      res['Content-Type'] = 'application/json'
      res.body = { status: "success", backup: backup_path }.to_json
    end
  end
end

# --- 6. LAUNCHER WITH PORT RECOVERY ---
port = 8085
server = nil

begin
  server = WEBrick::HTTPServer.new(Port: port, AccessLog: [], Logger: WEBrick::Log.new(nil, 0))
rescue Errno::EACCES, Errno::EADDRINUSE
  port += 1
  retry if port < 8100
end

server.mount '/', PwaServlet
puts ">>> SERVER RUNNING AT: http://localhost:#{port}"
system("start http://localhost:#{port}")
server.start
