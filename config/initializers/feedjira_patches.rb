# Feedjiraのパーサー自動検出の誤検出を修正するモンキーパッチ
#
# ITunesRSS.able_to_parse? はXML全体に対して xmlns:itunes の正規表現マッチをかけるが、
# Atomフィードの <content> 内CDATA にRSSのコードスニペット(xmlns:itunes宣言等)が
# 含まれていると誤検出してしまう。
# CDATA内のテキストを除外してからマッチするように修正する。
module FeedjiraITunesRSSPatch
  def able_to_parse?(xml)
    xml_without_cdata = xml.gsub(/<!\[CDATA\[.*?\]\]>/m, "")
    %r{xmlns:itunes\s?=\s?["']http://www\.itunes\.com/dtds/podcast-1\.0\.dtd["']}i =~ xml_without_cdata
  end
end

Feedjira::Parser::ITunesRSS.singleton_class.prepend(FeedjiraITunesRSSPatch)
