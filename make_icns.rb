#!/usr/bin/env ruby

iconset_dir = ARGV.fetch(0)
output_path = ARGV.fetch(1)

elements = [
  ["ic07", "icon_128x128.png"],
  ["ic08", "icon_256x256.png"],
  ["ic09", "icon_512x512.png"],
  ["ic10", "icon_512x512@2x.png"],
  ["ic13", "icon_256x256@2x.png"],
  ["ic14", "icon_512x512@2x.png"]
].map do |type, filename|
  data = File.binread(File.join(iconset_dir, filename))
  type + [8 + data.bytesize].pack("N") + data
end

icns = "icns" + [8 + elements.sum(&:bytesize)].pack("N") + elements.join
File.binwrite(output_path, icns)
