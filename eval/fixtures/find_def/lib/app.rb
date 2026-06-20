# frozen_string_literal: true

require_relative "widgets/button"
require_relative "widgets/slider"

# Top-level application wiring the widgets together.
class App
  def widgets
    [Widgets::Button.new, Widgets::Slider.new]
  end
end
