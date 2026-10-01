namespace :items do
  desc "URL になっていない Item#image_url を直す (#830)。APPLY=1 のときだけ書き換え、それ以外は直す内容を表示するだけ"
  task repair_image_urls: :environment do
    ItemImageUrlRepairer.run(apply: ENV["APPLY"] == "1")
  end
end
