module ValidationErrorsNotifiable
  extend ActiveSupport::Concern

  included do
    after_validation :notify_validation_errors
  end

  def notify_validation_errors
    return if errors.empty?

    content = [
      "#{self.class} save failed: #{errors.full_messages.join(", ")}",
      "```#{attributes.to_yaml}```",
    ].join("\n")
    DiscoPosterJob.perform_later(content: content)
  end
end
