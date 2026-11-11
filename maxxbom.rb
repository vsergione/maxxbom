require "sketchup.rb"
require "extensions.rb"

module Logimaxx
  module MaxxBOM
    # The only user-visible extension name. Menu, toolbar and dialog titles read it.
    DISPLAY_NAME = "MaxxBOM"
    VERSION = "0.1.0"

    # SketchUp loads only this file from the Plugins folder. The sources live in
    # a sibling folder with the same basename:
    #   maxxbom.rb
    #   maxxbom/main.rb
    # A copy of this loader in Plugins (dev) falls back to ~/work/maxxbom,
    # then to Z:\maxxbom, when that sibling folder is not installed beside it.
    def self.main_script
      candidates = [
        File.join(__dir__, "maxxbom", "main.rb"),
        File.join(__dir__, "main.rb")
      ]
      home = ENV["HOME"]
      home = ENV["USERPROFILE"] if home.nil? || home.empty?
      dev_roots = []
      dev_roots << File.join(home, "work", "maxxbom") if home && !home.empty?
      dev_roots << "Z:/maxxbom"
      dev_roots.each do |dev_root|
        candidates << File.join(dev_root, "maxxbom", "main.rb")
        candidates << File.join(dev_root, "main.rb")
      end
      candidates.find { |path| File.exist?(path) }
    end

    MAIN = main_script

    unless MAIN
      puts "[#{DISPLAY_NAME}] main.rb not found next to the loader, in ~/work/maxxbom, or in Z:\\maxxbom"
    else
      ex = SketchupExtension.new(DISPLAY_NAME, MAIN)
      ex.description = "BOM exporter for SketchUp"
      ex.version     = VERSION
      ex.creator     = "Logimaxx"
      Sketchup.register_extension(ex, true)
    end
  end
end
