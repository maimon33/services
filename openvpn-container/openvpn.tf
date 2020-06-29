# Create a new instance of the latest Ubuntu 14.04 on an
# t2.micro node with an AWS Tag naming it "HelloWorld"
provider "aws" {
  region = "eu-west-1"
}

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-*.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

resource "aws_key_pair" "openvpn" {
  key_name   = "openvpn-key"
  public_key = "rsa-key-20200620 AAAAB3NzaC1yc2EAAAABJQAAAQEAsV4UsJCsDuHkCF1QGyNWKKaNeygHutHpRqTlPwiM2XbHX0w56P1TbMhn8Pt21PgoX98f8YFbCZhxMH2uqGNz/Km5re6wM7WjMX9G4UmHaX2Llt//5l3wyZn7KWzK9HKqC8MsV3VZrVIskeVq/A4u9kyY0FCia1th7CceGQCwJA62+vDr3WEkaHkCEU+B1pXLnAHOqkk0CBDqO9K36vf1EVFAqfupYfFzxTCMj2jwkXN1F5A8ca7FU08m+bRv9Fcgcwe110RKhSMgTD05V+dmsaN6xShp+3OO44zDQgQ+pMjioRWrrqOnhWreXKjxBRhMaXgCRhON8yY8fqbJRpSfuQ=="
}

resource "aws_instance" "openvpn" {
  ami           = "${data.aws_ami.ubuntu.id}"
  instance_type = "t2.micro"

  tags = {
    Name = "Openvpn"
  }
}