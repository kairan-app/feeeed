module SlackBlockBuilder
  extend ActiveSupport::Concern

  def build_slack_blocks(channel, items)
    items_blocks = items.sort_by(&:id).reverse.take(4).map(&:to_slack_block)
    items_blocks.push(channel.to_slack_more_block) if items.size > 4

    [ channel.to_slack_header_block, *items_blocks ]
  end
end
