# frozen_string_literal: true

# Read must refuse binaries: passing a PNG / sqlite / ELF through the
# cat-with-line-numbers path floods the buffer with mojibake and burns tokens
# on output the model can't usefully parse. Return a clean error pointing at
# shell+xxd as the right way to inspect bytes.
RSpec.describe Rubino::Tools::ReadTool do
  subject(:tool) { described_class.new }

  let(:tmp_dir) { Dir.mktmpdir("read-binary") }

  after { FileUtils.rm_rf(tmp_dir) }

  def write_binary(name, bytes)
    path = File.join(tmp_dir, name)
    File.binwrite(path, bytes)
    path
  end

  describe "binary detection" do
    it "refuses a file containing NUL bytes" do
      path = write_binary("image.bin", "PNG\x89\x00\x00IHDR")
      out  = tool.call("file_path" => path)
      expect(out[:output]).to include("binary file")
      expect(out[:output]).to include("xxd")
      expect(out[:error_code]).to eq(:binary_file)
    end

    it "refuses a file with >30% non-printable bytes" do
      # 1KB of mostly 0x7F (DEL) which is non-printable but not NUL.
      path = write_binary("noise.bin", ("\x7F" * 500) + "ASCII tail")
      out  = tool.call("file_path" => path)
      expect(out[:output]).to include("binary file")
      expect(out[:error_code]).to eq(:binary_file)
    end

    it "still reads a text file with newlines and tabs" do
      path = write_binary("text.txt", "line1\n\tindented\nplain ascii\n")
      out  = tool.call("file_path" => path)
      expect(out).to be_a(Hash)
      expect(out[:output]).to include("line1")
      expect(out[:output]).to include("indented")
    end

    it "treats an empty file as text (read returns no useful body but no error)" do
      path = write_binary("empty.txt", "")
      out  = tool.call("file_path" => path)
      # No exception; either a sentinel message or empty body — both fine.
      payload = out.is_a?(Hash) ? out[:output] : out
      expect(payload).not_to include("binary file") if payload.is_a?(String)
    end

    it "still reads a UTF-8 text file with multi-byte characters" do
      path = write_binary("utf8.txt", "español 中文 🚀\nseconda riga\n")
      out  = tool.call("file_path" => path)
      expect(out).to be_a(Hash)
      expect(out[:output]).to include("español")
      expect(out[:output]).to include("中文")
    end

    # Regression: prod session 31 — a PDF with a long ASCII-ish prefix
    # (xref tables, /Length operators) passed the NUL + non-printable
    # checks; the binary bytes that followed then crashed the run when
    # JSON.generate hit them at the event boundary.
    it "refuses a PDF identified by the %PDF- magic header" do
      pdf_body = "%PDF-1.4\n" + ("%PDFcomment line\n" * 50) + "stream\n\xDE\xAD\xBE\xEF\nendstream\n"
      path = write_binary("doc.pdf", pdf_body)
      out  = tool.call("file_path" => path)
      expect(out[:output]).to include("binary file")
      expect(out[:error_code]).to eq(:binary_file)
    end

    it "refuses a PNG identified by its magic header" do
      png_body = "\x89PNG\r\n\x1A\n" + ("IHDR" * 20) + ("text section without nuls " * 30)
      path = write_binary("img.png", png_body)
      out  = tool.call("file_path" => path)
      expect(out[:error_code]).to eq(:binary_file)
    end

    it "refuses a ZIP / docx by its PK\\x03\\x04 magic header" do
      zip_body = "PK\x03\x04" + ("metadata padding " * 60)
      path = write_binary("archive.zip", zip_body)
      out  = tool.call("file_path" => path)
      expect(out[:error_code]).to eq(:binary_file)
    end
  end
end
