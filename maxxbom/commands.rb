# commands.rb — UI::Command definitions and menu actions
# ------------------------------------------------------------------------------
# SketchUp pitfall: menus and toolbars cannot be removed. They are created once
# per session and keep the original UI::Command objects across reload!.
# The block must resolve the method at click time (via full constant path) so
# the latest code runs.
# ------------------------------------------------------------------------------

module Logimaxx
  module MaxxBOM
    module Commands

      def self.reload_dev
        return unless Logimaxx::MaxxBOM.dev_mode?
        Logimaxx::MaxxBOM.reload!
        ::UI.messagebox("Reload completed.")
      end

      def self.export_bom
        Logimaxx::MaxxBOM::UI.show(:export_bom)
      end

      def self.rules
        Logimaxx::MaxxBOM::UI.show(:rules)
      end

      def self.settings
        Logimaxx::MaxxBOM::UI.show(:settings)
      end

      def self.to_be_implemented
        ::UI.messagebox("To be implemented 1")
      end

      def self.reload_dev_command
        cmd = ::UI::Command.new("Reload (Dev)") do
          Logimaxx::MaxxBOM::Commands.reload_dev
        end
        cmd.tooltip = 'Reload extension (dev only)'
        cmd.small_icon = File.join(ROOT, "icons","reload_16x16.png")
        cmd.large_icon = File.join(ROOT, "icons","reload_24x24.png")
        cmd.menu_text = "Reload (Dev)"
        cmd
      end

      def self.export_bom_command
        cmd = ::UI::Command.new('Export BOM') do
          Logimaxx::MaxxBOM::Commands.export_bom
        end
        cmd.tooltip = 'Export Bill of Materials'
        cmd.small_icon = File.join(ROOT, "icons","export_16x16.png")
        cmd.large_icon = File.join(ROOT, "icons","export_24x24.png")
        cmd.menu_text = "Export BOM"
        # Omit small_icon/large_icon unless you have paths; SketchUp does not accept nil.
        cmd
      end


      def self.rules_command
        cmd = ::UI::Command.new('Rules') do
          Logimaxx::MaxxBOM::Commands.rules
        end
        cmd.tooltip = 'Edit rules'
        cmd.small_icon = File.join(ROOT, "icons","rules_16x16.png")
        cmd.large_icon = File.join(ROOT, "icons","rules_24x24.png")
        cmd.menu_text = "Rules"
        cmd
      end

      def self.settings_command
        cmd = ::UI::Command.new('Settings') do
          Logimaxx::MaxxBOM::Commands.settings
        end
        cmd.tooltip = 'Plugin settings (API URL, etc.)'
        cmd.small_icon = File.join(ROOT, "icons", "settings_16x16.png")
        cmd.large_icon = File.join(ROOT, "icons", "settings_24x24.png")
        cmd.menu_text = "Settings"
        cmd
      end

      def self.to_be_implemented_command
        cmd = ::UI::Command.new('Undefined') do
          Logimaxx::MaxxBOM::Commands.to_be_implemented
        end
        cmd.tooltip = 'Undefined'
        cmd.small_icon = File.join(ROOT, "icons","question.png")
        cmd.large_icon = File.join(ROOT, "icons","question.png")
        cmd.menu_text = "To be implemented 1"
        cmd
      end

      
    end
  end
end


