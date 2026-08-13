# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :billing_details, /\Acharge\z/, /\Acustomer\z/, /\Acustomer_account\z/, /\Acustomer_address\z/,
  /\Acustomer_email\z/, /\Acustomer_name\z/, /\Acustomer_phone\z/, /\Acustomer_shipping\z/,
  /\Acustomer_tax_ids\z/, /\Acustomer_id\z/, /\Adata\z/, :hosted_invoice_url, :invoice_pdf, /\Alines\z/,
  /\Aprice_id\z/,
  :payment_intent, :payment_method, :receipt_url, /\Asource\z/, /\Asubscription_id\z/
]
