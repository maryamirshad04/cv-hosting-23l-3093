# Host Your CV on AWS

Maryam Irshad, roll number 23L-3093 (`23l-3093`).

My CV is kept in one **private** S3 bucket and served twice: by nginx on an EC2 instance, and by a Lambda function with a function URL.

| What | Address |
|---|---|
| EC2 site | http://54.206.227.188/ |
| Lambda site | https://ssewmyrg7lt7ihpgfc4wtuwu7a0apjwu.lambda-url.ap-southeast-2.on.aws/ |
| S3 bucket | `cv-23l-3093` (private, only the two roles can read it), Region ap-southeast-2 |

## 1. Diagram

```
                        +--------------------------------------+
                        |  S3 bucket cv-23l-3093  (PRIVATE)    |
                        |  site/index.html  site/style.css     |
                        |  site/cv.pdf      (versioning ON,    |
                        |  all 4 Block Public Access ON)       |
                        +----------------+---------------------+
                           ^ GetObject + ListBucket    ^ GetObject
                           | (EC2 role)                | (Lambda role)
   Path A                  |                           |                     Path B
 Visitor --HTTP 80--> EC2 instance (nginx)          Lambda function  <--HTTPS-- Visitor
                      sync-cv.sh copies site/       reads the file from S3     (function URL,
                      to the web root every 2 min   on every request           auth NONE)
```

**Path A (EC2):** the visitor's browser connects to the instance's public IP on port 80, and nginx returns files from its web root. `sync-cv.sh` copied those files from S3 (using the instance role) at boot and again every 2 minutes. It put `EC2 <instance id>` in the footer.
**Path B (Lambda):** the visitor's HTTPS request goes to the function URL and Lambda runs `lambda_function.py`. The function reads the requested file from S3 with its own role and returns it, with `Lambda <function name>` in the footer.

## 2. Access denied when changing the bucket (from the EC2 instance)

The commands were run on the instance over SSH. The instance role only has `s3:GetObject` and `s3:ListBucket`.

```
[ec2-user@ip-172-31-43-214 ~]$ aws s3 rm s3://cv-23l-3093/site/index.html
delete failed: s3://cv-23l-3093/site/index.html An error occurred (AccessDenied) when calling the DeleteObject operation: User: arn:aws:sts::501634099237:assumed-role/cv-ec2-role-23l-3093/i-0a7ebd5b57a92910d is not authorized to perform: s3:DeleteObject on resource: "arn:aws:s3:::cv-23l-3093/site/index.html" because no identity-based policy allows the s3:DeleteObject action
[ec2-user@ip-172-31-43-214 ~]$ echo test > /tmp/t.txt
[ec2-user@ip-172-31-43-214 ~]$ aws s3 cp /tmp/t.txt s3://cv-23l-3093/site/index.html
upload failed: ../../tmp/t.txt to s3://cv-23l-3093/site/index.html An error occurred (AccessDenied) when calling the PutObject operation: User: arn:aws:sts::501634099237:assumed-role/cv-ec2-role-23l-3093/i-0a7ebd5b57a92910d is not authorized to perform: s3:PutObject on resource: "arn:aws:s3:::cv-23l-3093/site/index.html" because no identity-based policy allows the s3:PutObject action
```

## 3. Last 10 lines of /var/log/cv-sync.log

```
[ec2-user@ip-172-31-43-214 ~]$ sudo tail -n 10 /var/log/cv-sync.log
2026-10-25T16:13:19Z sync OK (instance i-0a7ebd5b57a92910d)
2026-10-25T16:15:29Z sync OK (instance i-0a7ebd5b57a92910d)
2026-10-25T16:17:39Z sync OK (instance i-0a7ebd5b57a92910d)
2026-10-25T16:19:49Z sync OK (instance i-0a7ebd5b57a92910d)
2026-10-25T16:21:49Z sync OK (instance i-0a7ebd5b57a92910d)
2026-10-25T16:23:49Z sync OK (instance i-0a7ebd5b57a92910d)
2026-10-25T16:25:49Z sync OK (instance i-0a7ebd5b57a92910d)
2026-10-25T16:27:49Z sync OK (instance i-0a7ebd5b57a92910d)
2026-10-25T16:29:49Z sync OK (instance i-0a7ebd5b57a92910d)
2026-10-25T16:31:49Z sync OK (instance i-0a7ebd5b57a92910d)
```
The timer runs the sync every 2 minutes.

## 4. Answers

**1. Why do the instance and the function use roles instead of access keys? What could go wrong if the keys were in the user data?**
A role gives the instance or function short-lived credentials that AWS creates and rotates by itself, and nothing secret is stored anywhere. Keys are long-lived: they would sit in the user data, which can be read by anyone who can read the instance details or log in to it, and it is easy to commit them to a public repository by mistake. Whoever finds the keys can use them from anywhere, with everything the key is allowed to do, until someone notices and deactivates them. A role's permissions are also limited and changed in one place, and its credentials expire on their own.

**2. Someone pastes the S3 address of index.html into a browser. What do they see, and which setting causes that?**
They see an "Access Denied" error (HTTP 403, a small XML page), not the CV. The cause is that the bucket is private: all four Block Public Access settings are on, and there is no bucket policy or ACL that allows everyone. A request with no AWS credentials is therefore refused.

**3. Explain in your own words the permission on the function URL that lets anyone call it. Why is that acceptable for the function but not for the bucket?**
The function has a resource-based policy that says: any principal (`*`) may call `lambda:InvokeFunctionUrl` when the URL's auth type is `NONE` (and may invoke the function when it is called through the function URL). It only means "anyone may send a request to this function's URL". It is fine because the function decides what is returned: it can only ever answer with the three CV files or a 404, and what it can read in S3 is limited by its role. Making the bucket public would let anyone read or list every object directly, including files added later by mistake, with no code in between to control it.

**4. Compare the two paths. What do you pay for when nobody visits the site? What happens if the traffic grows a hundred times?**
With no visitors, EC2 still costs money: the instance runs and is billed by the hour, and its public IPv4 address and disk are billed too (inside the Free Tier or credits this may be covered). Lambda costs nothing when it is not called, because it is billed per request and run time. If traffic grows a hundred times, Lambda scales out automatically and the bill grows with the number of requests. One small EC2 instance would become slow or overloaded, so I would need a bigger instance or several of them behind a load balancer, and I would pay for them all the time.

**5. You delete the EC2 instance. What do you lose and what do you still have?**
I lose the running web server, its public IP address (so the EC2 address stops working and a new instance gets a different one), the root disk, and the local files on it, including `/var/log/cv-sync.log`. I still have the S3 bucket with the CV files and their versions, both IAM roles, the Lambda site and its logs, and the repository with `user-data.sh` and `sync-cv.sh`. I can create a new instance from the same user data and the site comes back.

## 5. Notes

- **Permissions without wildcards.** The only `*` in my policies is the end of the object path `arn:aws:s3:::cv-23l-3093/site/*`, which means "objects under `site/`". No action is a wildcard and no resource is `*`. The only exception is the AWS managed policy `AWSLambdaBasicExecutionRole` for logging.
- **Security group.** TCP 80 from anywhere. TCP 22 only from my own address (a /32). IMDSv2 is required.
- **Repository layout.** `site/` (the three files in S3), `ec2/` (user data and sync script), `lambda/` (function code), `iam/` (trust and permission JSON of both roles), `collect-evidence.sh` and `evidence.txt`.
- **No stored credentials.** The instance and the function get temporary permissions from their IAM roles. Nothing of that kind is in this repository, the user data, the function code or its environment, or on the instance.
- `user-data.sh` contains a copy of `sync-cv.sh`. If `sync-cv.sh` changes, the copy in `user-data.sh` must be updated.
