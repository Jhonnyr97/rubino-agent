# frozen_string_literal: true

require "zip"

# Top-level optional-gem probes used as RSpec `if:` metadata so the gem-backed
# fidelity examples are skipped (not failed) on an install without the gem --
# which is exactly the optional-require contract under test elsewhere.
def roo_available?
  require "roo"
  true
rescue LoadError
  false
end

def docx_available?
  require "docx"
  true
rescue LoadError
  false
end

def pdf_available?
  require "pdf/reader"
  true
rescue LoadError
  false
end

# Builds the binary document fixtures (xlsx/docx/pdf) used by the
# Rubino::Documents specs. The text fixtures (csv/json/xml/html/txt/rb) are
# committed as plain files; the binary ones are generated here so they can be
# regenerated deterministically rather than being opaque committed blobs:
#
#   ruby -r ./spec/support/document_fixtures -e \
#     'DocumentFixtures.generate!("spec/fixtures/documents")'
#
# Minimal but valid OOXML (zip) and PDF, each exercising a heading, a list/row,
# and structure -- enough to assert structural fidelity without LibreOffice.
module DocumentFixtures
  module_function

  def generate!(dir)
    require "fileutils"
    FileUtils.mkdir_p(dir)
    write_zip(File.join(dir, "sample.xlsx"), xlsx_files)
    write_zip(File.join(dir, "sample.docx"), docx_files)
    File.binwrite(File.join(dir, "sample.pdf"), pdf_bytes)
    File.binwrite(File.join(dir, "scanned.pdf"), scanned_pdf_bytes)
  end

  def write_zip(path, files)
    FileUtils.rm_f(path)
    Zip::File.open(path, create: true) do |zip|
      files.each { |name, content| zip.get_output_stream(name) { |f| f.write(content) } }
    end
  end

  # ---------------- XLSX ----------------
  def xlsx_files
    {
      "[Content_Types].xml" => <<~XML,
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
          <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
          <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        </Types>
      XML
      "_rels/.rels" => <<~XML,
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
      XML
      "xl/workbook.xml" => <<~XML,
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets><sheet name="Data" sheetId="1" r:id="rId1"/></sheets>
        </workbook>
      XML
      "xl/_rels/workbook.xml.rels" => <<~XML,
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        </Relationships>
      XML
      "xl/styles.xml" => <<~XML,
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>
          <fills count="1"><fill><patternFill patternType="none"/></fill></fills>
          <borders count="1"><border/></borders>
          <cellStyleXfs count="1"><xf/></cellStyleXfs>
          <cellXfs count="1"><xf/></cellXfs>
        </styleSheet>
      XML
      "xl/worksheets/sheet1.xml" => sheet_xml
    }
  end

  def sheet_xml
    rows = [%w[Quarter Revenue], %w[Q1 100], %w[Q2 150]]
    body = rows.each_with_index.map do |row, ri|
      cells = row.each_with_index.map { |val, ci| xlsx_cell("#{("A".ord + ci).chr}#{ri + 1}", val) }.join
      %(<row r="#{ri + 1}">#{cells}</row>)
    end.join
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <sheetData>#{body}</sheetData>
      </worksheet>
    XML
  end

  def xlsx_cell(ref, val)
    if val.match?(/\A-?\d+(\.\d+)?\z/)
      %(<c r="#{ref}"><v>#{val}</v></c>)
    else
      %(<c r="#{ref}" t="inlineStr"><is><t>#{val}</t></is></c>)
    end
  end

  # ---------------- DOCX ----------------
  def docx_files
    {
      "[Content_Types].xml" => <<~XML,
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
      XML
      "_rels/.rels" => <<~XML,
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
      XML
      "word/_rels/document.xml.rels" => <<~XML,
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
      XML
      "word/styles.xml" => styles_xml,
      "word/document.xml" => document_xml
    }
  end

  def styles_xml
    defs = {
      "Heading1" => "heading 1",
      "Heading2" => "heading 2",
      "ListParagraph" => "List Paragraph"
    }.map do |id, name|
      %(<w:style w:type="paragraph" w:styleId="#{id}"><w:name w:val="#{name}"/></w:style>)
    end.join
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        #{defs}
      </w:styles>
    XML
  end

  def document_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>
          #{docx_para("Project Plan", style: "Heading1")}
          #{docx_para(nil, runs: [["This is ", nil], ["important", { bold: true }], [" text.", nil]])}
          #{docx_para("Goals", style: "Heading2")}
          #{docx_para("First goal", style: "ListParagraph")}
          #{docx_para("Second goal", style: "ListParagraph")}
        </w:body>
      </w:document>
    XML
  end

  def docx_para(text, style: nil, runs: nil)
    # Always emit a <w:pPr>; the docx gem crashes resolving the style of a
    # paragraph that has no properties node at all.
    ppr = style ? %(<w:pPr><w:pStyle w:val="#{style}"/></w:pPr>) : "<w:pPr/>"
    body =
      if runs
        runs.map { |t, opts| docx_run(t, opts) }.join
      else
        %(<w:r><w:t xml:space="preserve">#{text}</w:t></w:r>)
      end
    "<w:p>#{ppr}#{body}</w:p>"
  end

  def docx_run(text, opts)
    rpr = +""
    rpr << "<w:b/>" if opts && opts[:bold]
    rpr << "<w:i/>" if opts && opts[:italic]
    rpr = "<w:rPr>#{rpr}</w:rPr>" unless rpr.empty?
    %(<w:r>#{rpr}<w:t xml:space="preserve">#{text}</w:t></w:r>)
  end

  # ---------------- PDF ----------------
  def pdf_bytes
    text = "BT /F1 18 Tf 72 720 Td (Quarterly Report) Tj " \
           "0 -28 Td /F1 12 Tf (Revenue grew this quarter.) Tj ET"
    objs = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
      "/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
      "<< /Length #{text.bytesize} >>\nstream\n#{text}\nendstream",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
    ]
    assemble_pdf(objs)
  end

  def scanned_pdf_bytes
    objs = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>",
      "<< /Length 0 >>\nstream\n\nendstream"
    ]
    assemble_pdf(objs)
  end

  def assemble_pdf(objs)
    out = +"%PDF-1.4\n"
    offsets = []
    objs.each_with_index do |body, i|
      offsets << out.bytesize
      out << "#{i + 1} 0 obj\n#{body}\nendobj\n"
    end
    xref_pos = out.bytesize
    out << "xref\n0 #{objs.size + 1}\n0000000000 65535 f \n"
    offsets.each { |o| out << format("%010d 00000 n \n", o) }
    out << "trailer\n<< /Size #{objs.size + 1} /Root 1 0 R >>\n"
    out << "startxref\n#{xref_pos}\n%%EOF"
    out
  end
end
