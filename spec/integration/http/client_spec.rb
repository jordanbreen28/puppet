require 'spec_helper'
require 'puppet_spec/https'
require 'puppet_spec/files'

describe Puppet::HTTP::Client, unless: Puppet::Util::Platform.jruby? do
  include PuppetSpec::Files

  before :all do
    WebMock.disable!
  end

  after :all do
    WebMock.enable!
  end

  before :each do
    # make sure we don't take too long
    Puppet[:http_connect_timeout] = '5s'
  end

  let(:hostname) { '127.0.0.1' }
  let(:wrong_hostname) { 'localhost' }
  let(:server) { PuppetSpec::HTTPSServer.new }
  let(:client) { Puppet::HTTP::Client.new }
  let(:ssl_provider) { Puppet::SSL::SSLProvider.new }
  let(:root_context) { ssl_provider.create_root_context(cacerts: [server.ca_cert], crls: [server.ca_crl]) }

  context "when verifying an HTTPS server" do
    it "connects over SSL" do
      server.start_server do |port|
        res = client.get(URI("https://127.0.0.1:#{port}"), ssl_context: root_context)
        expect(res).to be_success
      end
    end

    it "raises if the server's cert doesn't match the hostname we connected to" do
      server.start_server do |port|
        expect {
          client.get(URI("https://#{wrong_hostname}:#{port}"), ssl_context: root_context)
        }.to raise_error { |err|
          expect(err).to be_instance_of(Puppet::HTTP::ConnectionError)
          expect(err.message).to match(/Server hostname '#{wrong_hostname}' did not match server certificate; expected one of (.+)/)

          md = err.message.match(/expected one of (.+)/)
          expect(md[1].split(', ')).to contain_exactly('127.0.0.1', 'DNS:127.0.0.1', 'DNS:127.0.0.2')
        }
      end
    end

    it "raises if the server's CA is unknown" do
      wrong_ca = cert_fixture('netlock-arany-utf8.pem')
      alt_context = ssl_provider.create_root_context(cacerts: [wrong_ca], revocation: false)

      server.start_server do |port|
        expect {
          client.get(URI("https://127.0.0.1:#{port}"), ssl_context: alt_context)
        }.to raise_error(Puppet::HTTP::ConnectionError,
                         %r{certificate verify failed.* .self signed certificate in certificate chain for CN=Test CA.})
      end
    end
  end

  context "with client certs" do
    let(:ctx_proc) {
      -> ctx {
        # configures the server to require the client to present a client cert
        ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER | OpenSSL::SSL::VERIFY_FAIL_IF_NO_PEER_CERT
      }
    }

    it "mutually authenticates the connection" do
      client_context = ssl_provider.create_context(
        cacerts: [server.ca_cert], crls: [server.ca_crl],
        client_cert: server.server_cert, private_key: server.server_key
      )

      server.start_server(ctx_proc: ctx_proc) do |port|
        res = client.get(URI("https://127.0.0.1:#{port}"), ssl_context: client_context)
        expect(res).to be_success
      end
    end
  end
end
