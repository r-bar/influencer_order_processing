# Despite the name an instance of InfluencerOrders actually represents a single
# line item withion an order. These are used to generate order CSV's for the
# warehouse and ultimately resolve tracking via the InfluencerOrder#name.
#
# A logical order is represented by one or more InfluencerOrders with a shared
# `#name` value.
class InfluencerOrder < ApplicationRecord

  searchkick callbacks: :async, inheritance: true

  belongs_to :influencer
  has_one(:tracking, class_name: 'InfluencerTracking', foreign_key: 'order_name',
          primary_key: 'name')

  CSV_DATE_FMT = '%m/%d/%Y %H:%M'
  CSV_HEADERS = ["order_number","groupon_number","order_date","merchant_sku_item","quantity_requested","shipment_method_requested","shipment_address_name","shipment_address_street","shipment_address_street_2","shipment_address_city","shipment_address_state","shipment_address_postal_code","shipment_address_country","gift","gift_message","quantity_shipped","shipment_carrier","shipment_method","shipment_tracking_number","ship_date","groupon_sku","custom_field_value","permalink","item_name","vendor_id","salesforce_deal_option_id","groupon_cost","billing_address_name","billing_address_street","billing_address_city","billing_address_state","billing_address_postal_code","billing_address_country","purchase_order_number","product_weight","product_weight_unit","product_length","product_width","product_height","product_dimension_unit","customer_phone","incoterms","hts_code","3pl_name","3pl_warehouse_location","kitting_details","sell_price","deal_opportunity_id","shipment_strategy","fulfillment_method","country_of_origin","merchant_permalink","feature_start_date","feature_end_date","bom_sku","payment_method","color_code","tax_rate","tax_price"]
  LINE_ITEM_KEYS = [
    'product_id',
    'merchant_sku_item',
    'size',
    'quantity_requested',
    'item_name',
    'sell_price',
    'product_weight',
  ]
  ORDER_NUMBER_CHARACTERS = [('a'..'z').to_a, ('A'..'Z').to_a, ('0'..'9').to_a].flatten.to_a.freeze

  validates :name, presence: true, format: /\A#IN/
  validates :billing_address, presence: true
  validates :shipping_address, presence: true
  validates :line_item, presence: true
  validate :line_item_is_valid_hash
  validates :influencer_id, presence: true

  scope :search_import, ->{ includes(:tracking, :influencer) }

  # Generate a order number
  #
  # @param prefix: [String] A prefix for the order number. Defaults to '#IN'.
  def self.generate_order_number(prefix: '#IN')
    prefix + (0..9).map{ORDER_NUMBER_CHARACTERS.sample}.join
  end

  # Generate the name for a Order CSV based on the current time and date.
  #
  # @return [String] the file name
  def self.name_csv
    "Orders_#{Time.current.strftime("%Y_%m_%d_%H_%M_%S_%L")}.csv"
  end


  # Create a order from a given influencer and variant
  #
  # @param influencer [Influencer] influencer to create the order for
  # @param variant [ProductVariant] the product variant to sent the
  #   influencer
  # @param order_number: [String] create with the given order number / name
  #   instead of generating
  # @return [InfluencerOrder] the order created
  def self.create_from_influencer_variant(influencer, variant, options = {})
    # shipping lines blank most of the time
    shipping_lines = options[:shipping_lines]
    order_number = options[:order_number] || options[:name] || generate_order_number
    create!(
      name: order_number,
      processed_at: Time.current,
      billing_address: influencer.billing_address,
      shipping_address: influencer.shipping_address,
      shipping_lines: shipping_lines,
      line_item: variant_line_item(variant),
      influencer_id: influencer.id,
      shipment_method_requested: options[:shipment_method_requested]
    )
  end

  # Create line_item data from a given Product Variant
  #
  # @param variant [ProductVariant] the product variant
  # @param quantity [Integer] The line item quantity.
  # @return [Hash] line item data
  def self.variant_line_item(variant, quantity = 1)
    {
      'product_id' => variant.product_id,
      'merchant_sku_item' => variant.sku,
      'size' => variant.option1,
      'quantity_requested' => quantity,
      'item_name' => variant.product.title,
      'sell_price' => variant.price,
      'product_weight' => variant.weight,
    }
  end

  # Create a CSV from the given orders_list or from any orders that have not
  # been marked as uploaded.
  #
  # @param orders_list [Enumerable<InfluencerOrder>] an enumerable of orders to
  #   include in the CSV
  # @return [String] file path od the CSV
  def self.create_csv(orders_list = nil)
    orders = orders_list || where(uploaded_at: nil)
    # create empty CSV file with appropriate name
    filename = '/tmp/' + name_csv
    rows = orders.map(&:to_row_hash)
    clean_rows = rows.map{|row| row.map{|k, v| [k, Iconv.conv('ASCII//TRANSLIT', 'UTF-8', v.to_s)]}.to_h}
    logger.debug "#{orders.length} Order line items"
    file = CSV.open(filename, 'w', headers: CSV_HEADERS) do |csv|
      csv << CSV_HEADERS
      clean_rows.each{|data| csv << CSV_HEADERS.map{|key| data[key]} }
    end
    filename
  end

  # Create a hash of CSV data keyed by the CSV header names
  #
  # @return [Hash] Order CSV row data
  def to_row_hash
    {
      'order_number' => name,
      'order_date' => processed_at.try(:strftime, CSV_DATE_FMT),
      'customer_phone' => billing_address["phone"].try('gsub', /[^0-9]/, ''),
      'sell_price' => line_item['sell_price'],
      'quantity_requested' => 1,
      'merchant_sku_item' => line_item['merchant_sku_item'],
      'product_weight' => line_item['product_weight'],
      'item_name' => line_item['item_name'],
      'billing_address_name' => billing_address["name"],
      'billing_address_street' => billing_address["address1"],
      'billing_address_city' => billing_address["city"],
      'billing_address_postal_code' => billing_address["zip"],
      'billing_address_state' => billing_address["province_code"],
      'billing_address_country' => billing_address["country_code"],
      'shipment_address_name' => "#{shipping_address["first_name"]} #{shipping_address["last_name"]}",
      'shipment_address_street' => shipping_address["address1"],
      'shipment_address_street_2' => shipping_address["address2"],
      'shipment_address_city' => shipping_address["city"],
      'shipment_address_postal_code' => shipping_address["zip"],
      'shipment_address_state' => shipping_address["province_code"],
      'shipment_address_country' => shipping_address["country_code"],
      'shipment_method_requested' => shipment_method_requested,
      'gift' => 'FALSE',
    }
  end

  # the address to send the order to
  #
  # @return [Hash] address data
  def address
    self.class.address influencer
  end

  # Has the order been marked as uploaded to the warehouse
  # 
  # @return [Bool]
  def uploaded?
    !uploaded_at.nil?
  end

  # Provides a default of 'GROUND' for shipment_methed_requested
  #
  # @return [String]
  def shipment_method_requested
    attributes['shipment_method_requested'] || 'GROUND'
  end

  # The product variant associated with the order
  #
  # @return [ProductVariant]
  def product_variant
    ProductVariant.find_by sku: line_item['merchant_sku_item']
  end

  # The product associated with the order
  #
  # @return [Product]
  def product
    Product.find line_item['product_id']
  end

  # Override the data stored for searching orders to include influencers and
  # tracking.
  # 
  # @return [Hash] search data
  def search_data
    as_json.merge(influencer: influencer, tracking: tracking)
  end

  private

  # shapehash is a hash of key => Class. It is used to assert the keys and types
  # of test_hash
  def validate_hash(shape_hash, test_hash)
    shape_hash.flat_map do |k, type|
      if test_hash.keys.include? k && test_hash[k].class == type
        ["#{k} is should be a #{type}, but it is a #{test_hash[k].class}"]
      else
        []
      end
    end
  end

  def line_item_is_valid_hash
    shape_hash = {
      'product_id' => Integer,
      'merchant_sku_item' => String,
      'size' => String,
      'quantity_requested' => Integer,
      'item_name' => String,
      'sell_price' => Float,
      'product_weight' => Integer,
    }
    validate_hash(shape_hash, line_item).each{ |msg| errors.add(:line_item, msg) }
  end
end
