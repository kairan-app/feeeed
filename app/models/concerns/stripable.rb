module Stripable
  extend ActiveSupport::Concern

  included do
    class_attribute :stripable_columns
    before_save :strip_columns
  end

  class_methods do
    def strip_before_save(*columns)
      self.stripable_columns = columns
    end
  end

  def strip_columns
    self.stripable_columns.each do |column|
      self.send("#{column}=", self.send(column).strip) if self.send(column).respond_to?(:strip)
    end
  end
end
