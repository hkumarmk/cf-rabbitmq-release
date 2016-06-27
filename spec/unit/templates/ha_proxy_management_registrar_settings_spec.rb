require 'spec_helper'

RSpec.describe 'rabbitmq-haproxy NATS support', template: true do
	let(:rendered_template) do
		YAML.load(compiled_template('rabbitmq-haproxy', 'management_registrar_settings.yml', {
			'cf'=> {
				'nats'=>{
					'username'=>'nats-user',
					'password'=>'nats-password',
					'port'=>'1234',
					'machines'=>['awesome-host','rubbish-host']
				},
			},
			'rabbitmq-broker' => {
				'rabbitmq'=>{
					'management_ip'=>'1.2.3.4',
					'management_domain'=>'this.tld'
				},
				'registration_interval'=>'4s',
			}
		}))
	end

	it 'lists the message bus servers' do
		expect(rendered_template).to have_key('message_bus_servers')
		servers = rendered_template['message_bus_servers']

		expect(servers.length).to equal(2)

		server_one = servers[0]
		expect(server_one).to include('host'=>'awesome-host:1234')
		expect(server_one).to include('user'=>'nats-user')
		expect(server_one).to include('password'=>'nats-password')

		server_two = servers[1]
		expect(server_two).to include('host'=>'rubbish-host:1234')
		expect(server_two).to include('user'=>'nats-user')
		expect(server_two).to include('password'=>'nats-password')
	end

	it 'has correct routes' do
		expect(rendered_template).to have_key('routes')

		routes = rendered_template['routes']
		expect(routes.length).to equal(1)

		first_route = routes.first
		expect(first_route).to include('name' => 'this.tld')
		expect(first_route).to include('registration_interval' => '4s')
		expect(first_route).to include('port' => 15672)
		expect(first_route).to include('uris' => ['this.tld'])
	end
end
