class My::WrappedController < MyController
  def show
    @year = params[:year].to_i
    @title = "Wrapped #{@year}"

    year_range = Time.zone.local(@year, 1, 1).beginning_of_day..Time.zone.local(@year, 12, 31).end_of_day

    @stats = build_stats(year_range)
    @monthly_data = build_monthly_data(year_range)
    @has_prev_year = has_data_for_year?(@year - 1)
    @has_next_year = has_data_for_year?(@year + 1)
  end

  private

  def build_stats(year_range)
    {
      pawprints: current_user.pawprints.where(created_at: year_range).count,
      subscriptions: current_user.subscriptions.where(created_at: year_range).count,
      ownerships: current_user.ownerships.where(created_at: year_range).count,
      notification_webhooks: current_user.notification_webhooks.where(created_at: year_range).count,
      notification_emails: current_user.notification_emails.where(created_at: year_range).count
    }
  end

  def build_monthly_data(year_range)
    models = {
      pawprints: current_user.pawprints,
      subscriptions: current_user.subscriptions
    }

    monthly_data = {}
    models.each do |name, relation|
      monthly_data[name] = (1..12).to_h do |month|
        month_start = Time.zone.local(@year, month, 1).beginning_of_day
        month_end = month_start.end_of_month.end_of_day
        count = relation.where(created_at: month_start..month_end).count
        [ month, count ]
      end
    end

    monthly_data
  end

  def has_data_for_year?(year)
    year_range = Time.zone.local(year, 1, 1).beginning_of_day..Time.zone.local(year, 12, 31).end_of_day

    current_user.pawprints.where(created_at: year_range).exists? ||
      current_user.subscriptions.where(created_at: year_range).exists? ||
      current_user.ownerships.where(created_at: year_range).exists? ||
      current_user.notification_webhooks.where(created_at: year_range).exists? ||
      current_user.notification_emails.where(created_at: year_range).exists?
  end
end
