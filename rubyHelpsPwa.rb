require 'tempfile'

actual_dir = Dir.pwd

begin
  target_file = Dir.glob(File.join(actual_dir, "*.def")).first

  if target_file
    content = File.read(target_file, mode: 'rb').force_encoding('UTF-8')
    
    # Create a temporary file to hold the content
    # This avoids the "Command Line is too long" crash
    temp_txt = Tempfile.new(['data', '.txt'])
    temp_txt.write(content)
    temp_txt.close
    
    title = "File: #{File.basename(target_file)}"
    
    # PowerShell script that reads from the TEMP FILE instead of a string
    ps_script = <<~PS
      Add-Type -AssemblyName PresentationFramework;
      $window = New-Object Windows.Window;
      $window.Title = '#{title}';
      $window.Width = 800;
      $window.Height = 600;
      $window.WindowStartupLocation = 'CenterScreen';
      
      $textBox = New-Object System.Windows.Controls.TextBox;
      $textBox.Text = Get-Content -Path '#{temp_txt.path}' -Raw;
      $textBox.TextWrapping = 'NoWrap';
      $textBox.AcceptsReturn = $true;
      $textBox.VerticalScrollBarVisibility = 'Auto';
      $textBox.HorizontalScrollBarVisibility = 'Auto';
      $textBox.IsReadOnly = $true;
      $textBox.FontFamily = 'Consolas';
      
      $window.Content = $textBox;
      $window.ShowDialog() | Out-Null;
    PS
    
    # Execute PowerShell
    system("powershell -WindowStyle Hidden -Command \"#{ps_script.gsub("\n", " ")}\"")
    
    # Cleanup temp file
    temp_txt.unlink
  else
    system("powershell -WindowStyle Hidden -Command \"Add-Type -AssemblyName PresentationFramework; [System.Windows.MessageBox]::Show('No .def file found.', 'Error')\"")
  end
rescue Exception => e
  File.write(File.join(actual_dir, "FATAL_ERROR.txt"), e.message)
end
