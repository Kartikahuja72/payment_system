class CreateDeadLetterEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :dead_letter_events do |t|
      t.string  :topic,          null: false
      t.integer :partition,      null: false
      t.bigint  :offset,         null: false
      t.json    :payload,        null: false
      t.text    :error_message
      t.string  :consumer_class, null: false
      t.timestamps
    end

    add_index :dead_letter_events, :topic
    add_index :dead_letter_events, :created_at
  end
end
