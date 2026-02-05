class PunchcardPresenter
  WEEKS = 52
  COLOR_CLASSES = {
    0 => "bg-gray-100",
    1 => "bg-blue-200",
    2 => "bg-blue-300",
    3 => "bg-blue-500",
    4 => "bg-blue-700"
  }.freeze

  attr_reader :data, :today

  def initialize(data)
    @data = data
    @today = Date.current
  end

  def week_columns
    @week_columns ||= begin
      start_of_week = today.beginning_of_week(:sunday)
      (0...WEEKS).map do |week_offset|
        week_start = start_of_week - (WEEKS - 1 - week_offset).weeks
        (0..6).map do |day_offset|
          date = week_start + day_offset.days
          count = data[date] || 0
          { date: date, count: count }
        end
      end
    end
  end

  def color_class_for(day)
    COLOR_CLASSES[intensity_for(day)]
  end

  def future?(day)
    day[:date] > today
  end

  private

  def max_count
    @max_count ||= data.values.max || 1
  end

  def intensity_for(day)
    count = day[:count]
    return 0 if count == 0
    return 1 if count <= max_count * 0.25
    return 2 if count <= max_count * 0.5
    return 3 if count <= max_count * 0.75

    4
  end
end
