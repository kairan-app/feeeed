module EmptyStringsAreAlignedToNil
  extend ActiveSupport::Concern

  included do
    class_attribute :empty_strings_are_aligned_to_nil_columns
    before_validation :align_empty_strings_to_nil
  end

  class_methods do
    def empty_strings_are_aligned_to_nil(*columns)
      self.empty_strings_are_aligned_to_nil_columns = columns
    end
  end

  def align_empty_strings_to_nil
    empty_strings_are_aligned_to_nil_columns.each do |column|
      self[column] = nil if self[column].blank?
    end
  end
end
