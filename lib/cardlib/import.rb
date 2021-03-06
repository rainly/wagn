require 'csv'

module Cardlib
  class Import
    class << self
      def csv(opts={})
        #cardtype, csv_content
        csv = CSV.parse(opts[:data])
        fields = csv.shift
        cardtype = Card.const_get( opts[:cardtype] ) || raise("Invalid cardtype #{opts[:cardtype]}")
        
        name_index = 0 #fields.index(opts[:name_field]) || raise("name field '#{opts[:name]}' not found")
        content_index = nil #opts[:content_field] ? fields.index(opts[:content_field]) : nil
        
        csv.each do |record|
          # do name field
          next if record[name_index].strip.blank?
          base_card = cardtype.create :name=>record[name_index].strip, :content=>(content_index ? record[content_index].strip : "")
          
          record.each_with_index do |value, index|
            next if ( index == name_index or index == content_index )
            Card.create :name=> "#{base_card.name}+#{fields[index].strip}", :content=>(value ? value.strip : '')
          end
        end
      end 
    end
  end
end