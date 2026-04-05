Set-Location 'C:\Users\rapiduser\pad-oler-ssi-val'
$proc = Start-Process -FilePath 'C:\Program Files\R\R-4.5.2\bin\Rscript.exe' `
  -ArgumentList 'workflow/08_run_analysis_and_manuscript_report.R' `
  -WorkingDirectory 'C:\Users\rapiduser\pad-oler-ssi-val' `
  -RedirectStandardOutput 'C:\Users\rapiduser\pad-oler-ssi-val\logs\step8_stdout.txt' `
  -RedirectStandardError  'C:\Users\rapiduser\pad-oler-ssi-val\logs\step8_stderr.txt' `
  -NoNewWindow -Wait -PassThru
Write-Host "Exit code: $($proc.ExitCode)"
