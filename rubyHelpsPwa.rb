require 'json'
require 'tempfile'

actual_dir = Dir.pwd

# Helper to generate color (no changes here)
def generate_vui_color(name)
  hash = name.to_s.hash
  r = (hash & 0xFF0000) >> 16
  g = (hash & 0x00FF00) >> 8
  b = (hash & 0x0000FF)
  r = (r % 150) + 50; g = (g % 150) + 50; b = (b % 150) + 50
  brightness = (r * 299 + g * 587 + b * 114) / 1000
  { bg: "#%02x%02x%02x" % [r, g, b], fg: (brightness < 128 ? "White" : "Black") }
end

begin
  target_file = Dir.glob(File.join(actual_dir, "*.def")).first

  if target_file
    raw_content = File.read(target_file, mode: 'rb').force_encoding('UTF-8')
    
    all_fields = []
    all_vuis = []

    # 1. IMPROVED PARSER: Only match blocks at the start of the line
    # Using ^(\w+) ensures we don't match "vui" if it's indented inside another block
    raw_content.scan(/^(\w+)\s+\{(.*?)\n\}/m).each do |type, block_text|
      data = { "type" => type }
      block_text.scan(/^\s+([\w-]+)\s+:\s+(.*?)(?=\n\s+[\w-]+\s+:|\z)/m).each do |key, value|
        clean_value = value.gsub(/[\&\\]\n\s*/, '').strip
        data[key] = data.has_key?(key) ? ([data[key]].flatten << clean_value) : clean_value
      end
      
      if type == "field"
        instances = [data["display-instance"]].flatten
        data["parent_vui_ids"] = instances.compact.map { |inst| inst.split('\\').first }.reject { |id| id == "0" }.uniq
        all_fields << data
      elsif type == "vui"
        all_vuis << data
      end
    end

    # 2. DE-DUPLICATION LOGIC
    # We group by ID and only take the first occurrence of each VUI
    vuis = all_vuis.uniq { |v| v["id"] }.map do |v|
      colors = generate_vui_color(v["name"] || "Default")
      v.merge("bg_color" => colors[:bg], "fg_color" => colors[:fg])
    end
    
    # Fields don't usually duplicate, but let's be safe
    fields = all_fields.uniq { |f| f["id"] }

    # 3. SAVE TO JSON
    json_file = Tempfile.new(['def_data', '.json'])
    json_file.write({ fields: fields, vuis: vuis }.to_json)
    json_file.close

    # 4. GUI (The PowerShell code remains mostly the same, but now receives clean data)
    ps_file = Tempfile.new(['ui_script', '.ps1'])
    ps_code = <<~PS
      Add-Type -AssemblyName PresentationFramework
      $data = Get-Content -Path '#{json_file.path.gsub("/", "\\")}' -Raw | ConvertFrom-Json
      $window = New-Object Windows.Window
      $window.Title = "Remedy Visualizer - Deduplicated View"
      $window.Width = 1200; $window.Height = 900; $window.Background = "#FFFFFF"
      $scroll = New-Object System.Windows.Controls.ScrollViewer
      $mainLayout = New-Object System.Windows.Controls.StackPanel; $mainLayout.Padding = 20

      foreach ($v in $data.vuis) {
          $group = New-Object System.Windows.Controls.GroupBox
          $group.Header = " VIEW: $($v.name) "; $group.Margin = "0,0,0,30"
          $group.FontSize = 14; $group.FontWeight = "Bold"; $group.Foreground = "#333333"
          $wrap = New-Object System.Windows.Controls.WrapPanel; $wrap.Padding = 10
          $myFields = $data.fields | Where-Object { $_.parent_vui_ids -contains $v.id }
          
          foreach ($f in $myFields) {
              $border = New-Object System.Windows.Controls.Border
              $border.Width = 120; $border.Height = 110; $border.Margin = 6; $border.CornerRadius = 8
              if ($f.datatype -ne "35" -and $f.datatype -ne "36") {
                  $border.Background = $v.fg_color; $currentFg = $v.bg_color
                  $border.BorderThickness = 2; $border.BorderBrush = $v.bg_color
              } else {
                  $border.Background = $v.bg_color; $currentFg = $v.fg_color
                  $border.BorderThickness = 0
              }
              $stack = New-Object System.Windows.Controls.StackPanel; $stack.VerticalAlignment = "Center"
              $idTxt = New-Object System.Windows.Controls.TextBlock; $idTxt.Text = $f.id; $idTxt.TextAlignment = "Center"; $idTxt.FontSize = 9; $idTxt.Foreground = $currentFg; $idTxt.Opacity = 0.7
              $nameTxt = New-Object System.Windows.Controls.TextBlock; $nameTxt.Text = $f.name; $nameTxt.TextAlignment = "Center"; $nameTxt.FontSize = 10; $nameTxt.TextWrapping = "Wrap"; $nameTxt.FontWeight = "SemiBold"; $nameTxt.Foreground = $currentFg; $nameTxt.Padding = 4
              $null = $stack.Children.Add($idTxt); $null = $stack.Children.Add($nameTxt); $border.Child = $stack; $null = $wrap.Children.Add($border)
          }
          $group.Content = $wrap; $null = $mainLayout.Children.Add($group)
      }
      $scroll.Content = $mainLayout; $window.Content = $scroll; $null = $window.ShowDialog()
    PS
    
    ps_file.write(ps_code); ps_file.close
    system("powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File \"#{ps_file.path.gsub("/", "\\")}\"")
    json_file.unlink; ps_file.unlink
  else
    system("powershell -Command \"Add-Type -AssemblyName PresentationFramework; [System.Windows.MessageBox]::Show('No .def file found.')\"")
  end
rescue Exception => e
  File.write(File.join(actual_dir, "CRASH_LOG.txt"), e.message + "\n" + e.backtrace.join("\n"))
end
